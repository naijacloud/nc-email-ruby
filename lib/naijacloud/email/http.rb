# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "openssl"
require "time"
require "timeout"

module NaijaCloud
  module Email
    # The only place in the gem that touches the network.
    #
    # net/http from the standard library, no gem: this package holds a live
    # sending credential, so every third-party runtime dependency is another
    # maintainer who could ship a post-install script into a process that can
    # mail as a customer's verified domain. A faster HTTP client is not worth
    # that trade.
    class Transport
      # Full-jitter backoff, per section 4 of the SDK contract.
      RETRY_BASE_SECONDS = 0.5
      RETRY_CAP_SECONDS  = 8.0

      # A server that asks for an hour is almost always a misconfiguration, and a
      # caller blocked for an hour inside a web request is an outage. Honour the
      # header, but not past a minute.
      RETRY_AFTER_MAX_SECONDS = 60.0

      RETRYABLE_STATUSES = [408, 429].freeze

      # Raised by the per-attempt deadline. Its own class so it cannot be
      # confused with a Timeout::Error raised by anything else, and so it is
      # rescued exactly where the deadline is set.
      class AttemptDeadline < StandardError; end

      # Test seams. Overridden by the suite so retry timing is asserted rather
      # than waited out; there is no public constructor option for them because a
      # caller who can replace `sleep` can turn the backoff into a hot loop
      # against production.
      attr_writer :sleeper, :jitter

      def initialize(api_key:, base_url:, timeout:, max_retries:, user_agent:)
        @api_key     = api_key
        @base_uri    = base_url
        @timeout     = timeout
        @max_retries = max_retries
        @user_agent  = user_agent
        @sleeper     = ->(seconds) { sleep(seconds) }
        @jitter      = ->(ceiling) { Kernel.rand * ceiling }
      end

      # `body` arrives already serialized: the caller has to measure the encoded
      # payload against the 10 MiB limit anyway, and serializing a 10 MiB body
      # twice to avoid passing a String is a poor trade.
      #
      # `require_string`: a key the 2xx body must carry as a non-empty String
      # (the send response's `id`). A success without it is a malformed
      # response, raised as ServerError and not retried.
      def post(path, body, extra_headers = {}, require_string: nil)
        execute(:post, path, body, extra_headers, require_string)
      end

      def get(path, extra_headers = {})
        execute(:get, path, nil, extra_headers, nil)
      end

      # The key lives in this object, so both of these are overridden. Ruby prints
      # `inspect` for an object in an unhandled-exception trace and in irb, which
      # is how a bearer token ends up pasted into a GitHub issue.
      #
      # Fully qualified on purpose: inside this namespace the bare constant
      # `Email` resolves to the Email *response class*, not to this module.
      def inspect
        "#<NaijaCloud::Email::Transport base_url=#{@base_uri} " \
          "api_key=#{NaijaCloud::Email.redact_key(@api_key)}>"
      end
      alias to_s inspect

      # The same for dumps. YAML.dump(client.emails) reaches this object, and
      # Psych writes every instance variable unless encode_with says otherwise.
      def marshal_dump
        raise Error.new("a NaijaCloud::Email::Transport holds an API key and must not be serialized")
      end

      def encode_with(_coder)
        raise Error.new("a NaijaCloud::Email::Transport holds an API key and must not be serialized")
      end

      private

      def execute(method, path, body, extra_headers, require_string)
        attempt = 0

        loop do
          error       = nil
          retryable   = false
          retry_after = nil

          begin
            response = perform(method, path, body, extra_headers)
            status   = response.code.to_i

            return decode_success(response, status, require_string) if status >= 200 && status < 300

            retry_after = parse_retry_after(response["retry-after"])
            error       = build_error(response, status, retry_after)
            retryable   = retryable_status?(status)
          rescue AttemptDeadline, Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Timeout::Error => e
            # A client-side deadline. The request may well have reached the
            # server, which is why every send carries an idempotency key before
            # the first attempt rather than after the first failure.
            error     = TimeoutError.new("request timed out after #{@timeout}s (#{e.class})")
            retryable = true
          rescue SocketError, SystemCallError, OpenSSL::SSL::SSLError, IOError,
                 Net::HTTPBadResponse, Net::ProtocolError => e
            # Net::HTTPBadResponse and Net::ProtocolError are in this list because
            # a proxy answering with garbage instead of a status line would
            # otherwise escape as a raw net/http exception, and the promise this
            # SDK makes is that one `rescue NaijaCloud::Email::Error` covers
            # every failure mode.
            error     = ConnectionError.new("could not reach #{@base_uri.host}: #{e.class}: #{e.message}")
            retryable = true
          end

          raise error unless retryable && attempt < @max_retries

          @sleeper.call(delay_for(attempt, retry_after))
          attempt += 1
        end
      end

      # One attempt, bounded by one deadline covering connect, write and the
      # whole response read. net/http's own timeouts are per socket operation, so
      # a server trickling a byte every few seconds would never trip
      # read_timeout and could hold a caller for ever; the outer deadline is what
      # makes `timeout` mean "this attempt takes at most N seconds".
      def perform(method, path, body, extra_headers)
        Timeout.timeout(@timeout, AttemptDeadline) do
          perform_attempt(method, path, body, extra_headers)
        end
      end

      def perform_attempt(method, path, body, extra_headers)
        uri = request_uri(path)

        # #hostname, not #host: #host keeps the brackets on an IPv6 literal, and
        # Net::HTTP would then try to resolve "[::1]" and never connect.
        http = Net::HTTP.new(uri.hostname, uri.port)
        http.use_ssl = uri.scheme == "https"
        # Set explicitly rather than relying on the default. OpenSSL's ambient
        # configuration can be changed by anything else loaded in the process, and
        # a client that silently stops verifying certificates is the worst kind of
        # regression: it keeps working.
        http.verify_mode  = OpenSSL::SSL::VERIFY_PEER
        http.open_timeout = @timeout
        http.read_timeout = @timeout
        http.write_timeout = @timeout if http.respond_to?(:write_timeout=)

        # net/http retries idempotent requests once on its own by default. Left
        # alone it would silently double the attempt count and re-send a POST
        # that may already have been accepted, outside the retry accounting in
        # this file. Our policy is the only one.
        http.max_retries = 0

        # Never call http.set_debug_output: it writes every header, including
        # Authorization, to whatever IO it is given. There is deliberately no
        # verbose mode in this gem for that reason.

        request = build_request(method, uri, body, extra_headers)
        http.start { |conn| conn.request(request) }
      end

      def build_request(method, uri, body, extra_headers)
        klass = method == :post ? Net::HTTP::Post : Net::HTTP::Get
        request = klass.new(uri.request_uri)

        request["Authorization"] = "Bearer #{@api_key}"
        request["Accept"]        = "application/json"
        request["User-Agent"]    = @user_agent

        extra_headers.each { |name, value| request[name] = value }

        if body
          request["Content-Type"] = "application/json"
          request.body = body
        end

        request
      end

      def request_uri(path)
        uri = @base_uri.dup
        base_path = uri.path.to_s.sub(%r{/+\z}, "")
        uri.path = "#{base_path}#{path}"
        uri
      end

      def decode_success(response, status, require_string)
        parsed = parse_json(response.body)

        unless parsed.is_a?(Hash)
          raise ServerError.new(
            "malformed response: expected a JSON object from the API, got #{status_line(response, status)}",
            status_code: status,
            request_id: response["x-request-id"],
            body: response.body,
            parsed_body: parsed,
            retryable: false,
          )
        end

        if require_string && !(parsed[require_string].is_a?(String) && !parsed[require_string].empty?)
          raise ServerError.new(
            "malformed response: \"#{require_string}\" is missing",
            status_code: status,
            request_id: response["x-request-id"],
            body: response.body,
            parsed_body: parsed,
            retryable: false,
          )
        end

        parsed
      end

      def build_error(response, status, retry_after)
        # net/http does not follow redirects unless you write the loop yourself,
        # so nothing here has to be switched off -- but a 3xx is still turned into
        # a hard error rather than left to fall through as "some other status",
        # because the reason it must never be followed is worth stating in the
        # error a caller actually sees: following it would re-send this
        # Authorization header to whatever host the response named.
        if status >= 300 && status < 400
          return ServerError.new(
            "unexpected redirect (#{status}) from #{@base_uri.host}; the API does not redirect and " \
            "this client will not resend credentials to another host",
            status_code: status,
            request_id: response["x-request-id"],
            body: response.body,
            parsed_body: parse_json(response.body),
            retryable: false,
          )
        end

        parsed  = parse_json(response.body)
        payload = parsed.is_a?(Hash) ? parsed : {}

        message = error_message(payload, response, status)
        common  = {
          status_code: status,
          error_label: payload["error"],
          request_id: response["x-request-id"],
          body: response.body,
          parsed_body: parsed,
        }

        case status
        when 400
          # A known control-plane quirk: an unknown message id answers 400 with
          # this exact string instead of 404. Matched on the message because it is
          # the only thing that distinguishes it, and mapped here so callers write
          # one rescue that keeps working when the server is fixed.
          if message.to_s.downcase.include?("message not found")
            NotFoundError.new(message, **common)
          else
            ValidationError.new(message, **common)
          end
        when 401 then AuthenticationError.new(message, **common)
        when 403 then PermissionError.new(message, **common)
        when 404 then NotFoundError.new(message, **common)
        when 408 then TimeoutError.new(message, **common)
        when 409 then ConflictError.new(message, **common)
        # 413 is the server's body parser refusing an oversized request: the
        # caller's input, and no retry will shrink it.
        when 413, 422 then ValidationError.new(message, **common)
        when 429 then RateLimitError.new(message, retry_after: retry_after, **common)
        else
          if status >= 500
            ServerError.new(message, **common)
          else
            # Any other 4xx (405, 415, 451...): the request as sent will never
            # succeed, which is what ValidationError means to a caller. Same in
            # all five SDKs (contract section 3).
            ValidationError.new(message, **common)
          end
        end
      end

      # NestJS sends `message` as either a string or an array of strings (one per
      # failed validation rule). A body that is not JSON at all -- a proxy's HTML
      # error page, or nothing -- is the case that matters most: it happens when
      # something between the caller and us is broken, and an SDK that raises
      # JSON::ParserError there hides the status code that would have explained it.
      def error_message(payload, response, status)
        message = payload["message"]

        case message
        when Array
          strings = message.map(&:to_s).reject(&:empty?)
          strings.empty? ? status_line(response, status) : strings.join("; ")
        when String
          message.empty? ? status_line(response, status) : message
        else
          status_line(response, status)
        end
      end

      def status_line(response, status)
        reason = response.message.to_s.strip
        reason.empty? ? "HTTP #{status}" : "HTTP #{status} #{reason}"
      end

      def parse_json(body)
        return nil if body.nil? || body.empty?

        JSON.parse(body)
      rescue JSON::ParserError
        nil
      end

      def retryable_status?(status)
        RETRYABLE_STATUSES.include?(status) || status >= 500
      end

      # Retry-After is defined as either a delta in seconds or an HTTP date, and
      # real proxies send both. Anything unparseable is ignored rather than
      # treated as zero, so a malformed header falls back to normal backoff
      # instead of turning a rate limit into a tight retry loop.
      def parse_retry_after(value)
        return nil if value.nil?

        raw = value.to_s.strip
        return nil if raw.empty?

        seconds =
          if raw =~ /\A\d+\z/
            raw.to_i.to_f
          else
            begin
              Time.httpdate(raw) - Time.now
            rescue ArgumentError
              return nil
            end
          end

        seconds = 0.0 if seconds.negative?
        [seconds, RETRY_AFTER_MAX_SECONDS].min
      end

      def delay_for(attempt, retry_after)
        return retry_after if retry_after

        # Full jitter. The alternative -- every client sleeping the same
        # exponential interval -- rebuilds the thundering herd that caused the
        # 429 in the first place.
        ceiling = [RETRY_CAP_SECONDS, RETRY_BASE_SECONDS * (2**attempt)].min
        @jitter.call(ceiling)
      end
    end
  end
end
