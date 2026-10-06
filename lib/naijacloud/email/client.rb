# frozen_string_literal: true

require "uri"

module NaijaCloud
  module Email
    # The entry point.
    #
    #   nm = NaijaCloud::Email::Client.new          # reads NAIJAMAIL_API_KEY
    #   nm.emails.send_email(from: ..., to: ..., subject: ..., html: ...)
    #
    # Everything a request needs -- key, base URL, timeouts, HTTP object -- hangs
    # off the instance. No class-level configuration, no singleton: two clients
    # holding two different teams' keys have to be able to run in one process
    # without one quietly borrowing the other's credential.
    class Client
      DEFAULT_BASE_URL = "https://api.naijacloud.com"

      API_KEY_ENV  = "NAIJAMAIL_API_KEY"
      BASE_URL_ENV = "NAIJAMAIL_BASE_URL"

      # The shape the control plane mints (MAIL_KEY_PREFIX_LIVE / _TEST plus 24
      # random bytes, base64url). Checked at construction so an empty string or a
      # truncated copy-paste fails here, on the developer's machine, rather than
      # as a 401 in production an hour after deploy.
      #
      # A test key is accepted by the constructor and refused by the send path
      # with 403 -- that refusal is the server's job and is deliberate, so this
      # SDK must not pre-empt it.
      #
      # Two families, because the API accepts two: `nmail_live_`/`nmail_test_`
      # is a Naijamail-only key from the Email screen, and `nc_live_` is a
      # workspace API key carrying the Email send scope, from Settings -> API
      # keys. It stays an allowlist rather than relaxing to "any non-empty
      # string": the check exists to catch the truncated paste and the
      # wrong-variable-name deploy, and a pattern that accepts anything catches
      # neither.
      KEY_PATTERN = /\A(?:nmail_(?:live|test)|nc_live)_[A-Za-z0-9_-]{8,}\z/.freeze

      # The only hosts allowed to be plaintext, for a developer running the
      # control plane locally. Everything else must be https: a bearer key that
      # can mail as a customer's verified domain has no business on the wire in
      # clear, and "it was only staging" is how it gets there.
      LOCAL_HOSTS = ["localhost", "127.0.0.1", "::1"].freeze

      # More retries than this only stretches an outage into a hang: with the
      # 8s backoff cap and a 30s per-attempt deadline, ten retries is already
      # minutes of a caller blocked on one send.
      MAX_RETRIES_LIMIT = 10

      # The platform's pre-scope personal access token. The API refuses it on the
      # mail routes; saying so here beats "not shaped like a key" (it is a real
      # NaijaCloud credential, just the wrong kind). Wording fixed by SDK
      # contract section 1, identical in all five SDKs.
      PAT_PREFIX  = "nc_pat_"
      PAT_MESSAGE = "this is a personal access token (nc_pat_…), which cannot send mail; " \
                    "use a mail API key (nmail_live_… or nmail_test_…) or a workspace API key " \
                    "with the Email send scope (nc_live_…)"

      attr_reader :base_url, :timeout, :max_retries, :user_agent

      def initialize(api_key: nil, base_url: nil, timeout: 30, max_retries: 2, user_agent_suffix: nil)
        key          = resolve_api_key(api_key)
        @base_uri    = resolve_base_url(base_url)
        @base_url    = @base_uri.to_s
        @timeout     = validate_timeout(timeout)
        @max_retries = validate_max_retries(max_retries)
        @user_agent  = build_user_agent(user_agent_suffix)

        # The key is deliberately NOT kept as an instance variable of the client:
        # it is handed to the transport, which is the only object that needs it,
        # and the local goes out of scope here. Anything that walks a client's
        # instance variables -- an error reporter serializing the receiver, a
        # console session, a naive deep-inspect in a test failure -- then has
        # nothing to find, because the transport redacts its own inspect too.
        @key_display = NaijaCloud::Email.redact_key(key)

        @http = Transport.new(
          api_key: key,
          base_url: @base_uri,
          timeout: @timeout,
          max_retries: @max_retries,
          user_agent: @user_agent,
        )

        @emails = Emails.new(@http)
      end

      # The one resource. Two endpoints, because the server has two.
      attr_reader :emails

      # Both overridden, and neither mentions @api_key.
      #
      # This is not decoration. An unhandled exception prints the receiver's
      # inspect, `p client` in a console prints it, a JSON logger calling to_s on
      # its context prints it, and any of those is a live sending credential in a
      # log aggregator that a much wider group of people can read than should
      # ever see it. The default Object#inspect would print every instance
      # variable, and the transport's key with it.
      def inspect
        "#<NaijaCloud::Email::Client base_url=#{@base_url} api_key=#{@key_display} " \
          "timeout=#{@timeout} max_retries=#{@max_retries}>"
      end
      alias to_s inspect

      # Marshal/YAML dumps of a client would carry the key into whatever wrote
      # them. There is no reason to serialize a client, so refuse rather than
      # produce a file nobody realises is a secret.
      def marshal_dump
        raise Error.new("a NaijaCloud::Email::Client holds an API key and must not be serialized")
      end

      # Psych does not use marshal_dump: it walks instance variables, down
      # @http to the key. encode_with is the hook it does call.
      def encode_with(_coder)
        raise Error.new("a NaijaCloud::Email::Client holds an API key and must not be serialized")
      end

      private

      def resolve_api_key(api_key)
        # ENV values pick up a trailing newline surprisingly often (`export
        # KEY=$(cat key.txt)`), and a newline in a header value is a header
        # injection, so strip before validating rather than after.
        key = api_key.nil? ? ENV[API_KEY_ENV] : api_key
        key = key.strip if key.is_a?(String)

        if key.nil? || key.empty?
          raise ValidationError.new(
            "no API key. Pass api_key: to the constructor or set #{API_KEY_ENV} in the environment.",
          )
        end
        raise ValidationError.new(PAT_MESSAGE) if key.is_a?(String) && key.start_with?(PAT_PREFIX)

        unless key.is_a?(String) && key =~ KEY_PATTERN
          # The key itself is never echoed, not even a "got: ..." fragment: this
          # message goes straight into a log on a failed boot.
          raise ValidationError.new(
            "API key does not look like a Naijamail key " \
            "(expected nmail_live_..., nmail_test_... or nc_live_...)",
          )
        end

        key
      end

      def resolve_base_url(base_url)
        # A blank NAIJAMAIL_BASE_URL (an empty `export` in a deploy config) means
        # "not set", not "invalid": the default applies, as in every other SDK.
        env = ENV[BASE_URL_ENV]
        env = nil if env.nil? || env.strip.empty?

        raw = base_url || env || DEFAULT_BASE_URL
        raw = raw.to_s.strip

        uri =
          begin
            URI.parse(raw)
          rescue URI::InvalidURIError => e
            raise ValidationError.new("base_url is not a valid URL: #{e.message}")
          end

        unless uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty?
          raise ValidationError.new("base_url must be an absolute http(s) URL, got #{raw.inspect}")
        end

        # A query or fragment would sit after every path this client appends, so
        # the request would go somewhere other than where the caller thinks.
        # Refused rather than stripped: silently dropping part of a configured
        # URL hides a configuration mistake.
        if uri.query || uri.fragment
          raise ValidationError.new("base_url must not contain a query string or a fragment")
        end

        # URI#host keeps the brackets on an IPv6 literal ("[::1]"); #hostname
        # strips them.
        host = uri.hostname.downcase

        if uri.scheme != "https" && !LOCAL_HOSTS.include?(host)
          raise ValidationError.new(
            "base_url must use https (got #{uri.scheme.inspect} for host #{host.inspect}). " \
            "Plaintext is allowed only for localhost, 127.0.0.1 and ::1.",
          )
        end

        uri
      end

      def validate_timeout(timeout)
        unless timeout.is_a?(Numeric) && timeout.to_f > 0
          raise ValidationError.new("timeout must be a positive number of seconds")
        end

        timeout.to_f
      end

      def validate_max_retries(max_retries)
        unless max_retries.is_a?(Integer) && max_retries >= 0 && max_retries <= MAX_RETRIES_LIMIT
          raise ValidationError.new("max_retries must be an Integer from 0 to #{MAX_RETRIES_LIMIT}")
        end

        max_retries
      end

      # Identifies the SDK in our logs, which is how we tell an SDK bug from a
      # customer's hand-rolled client. The suffix is checked for CR/LF for the
      # same reason every other header value is: it ends up in one.
      def build_user_agent(suffix)
        agent = "nc-email-ruby/#{VERSION} (ruby/#{RUBY_VERSION})"
        return agent if suffix.nil?

        unless suffix.is_a?(String)
          raise ValidationError.new("user_agent_suffix must be a string")
        end
        if suffix =~ /[\r\n\0]/
          raise ValidationError.new("user_agent_suffix contains a line break or NUL")
        end

        suffix = suffix.strip
        suffix.empty? ? agent : "#{agent} #{suffix}"
      end
    end
  end
end
