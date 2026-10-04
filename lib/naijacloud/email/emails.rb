# frozen_string_literal: true

require "json"
require "securerandom"

begin
  require "base64"
rescue LoadError
  # base64 stops being a default gem in Ruby 3.4. Nothing to do here: the encoder
  # below falls back to pack("m0"), which produces byte-identical output to
  # Base64.strict_encode64. Declaring a runtime dependency to keep one method
  # would put a third-party release into a package that holds a sending key.
  nil
end

module NaijaCloud
  module Email
    # The `emails` resource: the two endpoints the control plane actually has.
    #
    # There is no domains, api-keys, batch or contacts resource here. Those exist
    # in other vendors' SDKs and not in ours because they do not exist server-side
    # -- an SDK method that returns 404 for everyone is worse than no method.
    class Emails
      # Mirrors SENDING_LIMITS in nc-control-plane/src/mail/mail.constants.ts.
      # Checked locally so a caller with 200 recipients gets an immediate,
      # readable error instead of paying a round trip to learn the same thing
      # from a machine they cannot see.
      MAX_RECIPIENTS    = 50
      MAX_HEADERS       = 25
      MAX_TAGS          = 10
      MAX_TAG_KEY_LEN   = 64
      MAX_TAG_VALUE_LEN = 256
      MAX_PAYLOAD_BYTES = 10 * 1024 * 1024

      # Overriding any of these would sidestep the domain authorisation that the
      # From address is checked against, so they are refused before the request is
      # built. The server refuses them too; this is the copy the caller can read.
      FORBIDDEN_HEADERS = %w[from to cc bcc subject dkim-signature received].freeze

      # CR and LF end a header; a NUL truncates it in some downstream parsers.
      # Either one, anywhere a value reaches a MIME header, is an injected header
      # -- a Bcc the sender never wrote, or a second message body.
      UNSAFE_CHARS = /[\r\n\0]/.freeze

      # RFC 7230 token characters. A header name with a colon or a space in it is
      # not a name the caller meant; it is the start of an injection attempt or a
      # typo that would produce an unparseable message.
      HEADER_NAME = /\A[A-Za-z0-9!\#$%&'*+\-.^_`|~]+\z/.freeze

      # Message ids are UUIDs. Rather than percent-encode an arbitrary string into
      # the path -- and get it subtly wrong -- anything outside this set is
      # rejected, so nothing a caller passes can add a path segment or a query.
      ID_PATTERN = /\A[A-Za-z0-9._:-]{1,255}\z/.freeze

      ALLOWED_KEYS = %w[
        from to cc bcc reply_to replyTo subject html text
        headers attachments tags idempotency_key
      ].freeze

      ALLOWED_ATTACHMENT_KEYS = %w[filename content content_type content_id].freeze

      def initialize(transport)
        @transport = transport
      end

      # Send a message.
      #
      # Named `send_email`, not `send`. `send` is Object#send: defining it here
      # would shadow the method every Ruby object uses to dispatch by name, so
      # `emails.send(:get, id)` -- and anything in a caller's stack that
      # metaprograms over this object, including some mocking libraries -- would
      # silently try to mail someone. `create` is the alias for callers who prefer
      # the REST-ish spelling.
      #
      # Takes keywords or a single Hash; on both Ruby 2.7 and 3.x a method with no
      # keyword parameters receives keywords as one Hash, so the two call styles
      # are the same call.
      def send_email(params = {})
        params = normalize_params(params)

        from = required_address(params["from"], "from")
        to   = address_list(params["to"], "to")
        raise ValidationError.new('"to" is required and must contain at least one address') if to.empty?

        cc       = address_list(params["cc"], "cc")
        bcc      = address_list(params["bcc"], "bcc")
        reply_to = address_list(params["reply_to"] || params["replyTo"], "reply_to")

        recipients = to.length + cc.length + bcc.length
        if recipients > MAX_RECIPIENTS
          raise ValidationError.new(
            "too many recipients: #{recipients} across to, cc and bcc (limit #{MAX_RECIPIENTS})",
          )
        end

        subject = optional_string(params["subject"], "subject") || ""
        check_unsafe!(subject, "subject")

        payload = {
          "from" => from,
          # Always an array, even for one recipient: the server accepts both, and
          # an array removes any question of how a comma inside a display name
          # would be split.
          "to" => to,
          "subject" => subject,
        }
        payload["cc"]          = cc unless cc.empty?
        payload["bcc"]         = bcc unless bcc.empty?
        payload["reply_to"]    = reply_to unless reply_to.empty?
        html = optional_string(params["html"], "html")
        text = optional_string(params["text"], "text")
        payload["html"] = html if html
        payload["text"] = text if text

        headers = build_headers(params["headers"])
        payload["headers"] = headers unless headers.empty?

        attachments = build_attachments(params["attachments"])
        payload["attachments"] = attachments unless attachments.empty?

        tags = build_tags(params["tags"])
        payload["tags"] = tags unless tags.empty?

        body = JSON.generate(payload)
        if body.bytesize > MAX_PAYLOAD_BYTES
          raise ValidationError.new(
            "encoded message is #{body.bytesize} bytes, over the #{MAX_PAYLOAD_BYTES}-byte limit",
          )
        end

        # Generated once, here, and reused by every attempt the transport makes.
        # This is the whole reason retrying a POST is safe: a timeout tells the
        # caller nothing about whether the message was accepted, and without a
        # stable dedup key the retry that follows mails the customer twice.
        idempotency_key = idempotency_key_for(params["idempotency_key"])

        response = @transport.post("/v1/emails", body, "Idempotency-Key" => idempotency_key)
        SendEmailResponse.from_hash(response)
      end

      alias create send_email

      # Fetch one message's current state. Scoped to the key's team server-side.
      def get(id)
        unless id.is_a?(String) && id =~ ID_PATTERN
          raise ValidationError.new("a message id is required and must be a plain id string")
        end
        # A dot segment would still be inside the character set above, and some
        # proxies and routers collapse it -- "/v1/emails/.." becomes a request
        # for something else entirely. Ids never contain one.
        if id.include?("..")
          raise ValidationError.new("a message id cannot contain a path segment")
        end

        Email.from_hash(@transport.get("/v1/emails/#{id}"))
      end

      private

      def normalize_params(params)
        params = params.to_h if params.respond_to?(:to_h) && !params.is_a?(Hash)
        unless params.is_a?(Hash)
          raise ValidationError.new("send_email expects keyword arguments or a Hash")
        end

        normalized = {}
        params.each { |key, value| normalized[key.to_s] = value }

        # Unknown keys are refused rather than forwarded. A typo -- `htlm:` for
        # `html:` -- would otherwise be dropped silently by the server and send a
        # blank email to a real customer, which is the failure this SDK exists to
        # make impossible.
        unknown = normalized.keys - ALLOWED_KEYS
        unless unknown.empty?
          raise ValidationError.new(
            "unknown parameter(s): #{unknown.sort.join(', ')}. Accepted: #{(ALLOWED_KEYS - ['replyTo']).join(', ')}",
          )
        end

        normalized
      end

      def required_address(value, field)
        unless value.is_a?(String) && !value.strip.empty?
          raise ValidationError.new("\"#{field}\" is required and must be a string")
        end

        check_unsafe!(value, field)
        check_addressish!(value, field)
        value
      end

      def address_list(value, field)
        return [] if value.nil?

        list = value.is_a?(Array) ? value : [value]
        list.each_with_index.map do |entry, index|
          label = value.is_a?(Array) ? "#{field}[#{index}]" : field
          unless entry.is_a?(String) && !entry.strip.empty?
            raise ValidationError.new("#{label} must be a non-empty string")
          end

          check_unsafe!(entry, label)
          check_addressish!(entry, label)
          entry
        end
      end

      # Deliberately not an RFC 5322 parser. Every regex that claims to validate
      # an address rejects something legitimate, and the authoritative check runs
      # server-side against the verified domain anyway. A missing "@" is the one
      # mistake worth catching here because it is always a mistake.
      def check_addressish!(value, field)
        return if value.include?("@")

        raise ValidationError.new("#{field} does not look like an email address: #{value.inspect}")
      end

      def check_unsafe!(value, field)
        return unless value.is_a?(String) && value =~ UNSAFE_CHARS

        raise ValidationError.new(
          "#{field} contains a line break or NUL, which would inject a mail header",
        )
      end

      def optional_string(value, field)
        return nil if value.nil?
        raise ValidationError.new("#{field} must be a string") unless value.is_a?(String)

        value
      end

      def build_headers(raw)
        return {} if raw.nil?
        raise ValidationError.new("headers must be a Hash of strings") unless raw.is_a?(Hash)

        headers = {}
        raw.each do |name, value|
          name = name.to_s
          raise ValidationError.new("a header name cannot be empty") if name.empty?

          unless name =~ HEADER_NAME
            raise ValidationError.new("header name #{name.inspect} is not a valid header name")
          end
          if FORBIDDEN_HEADERS.include?(name.downcase)
            raise ValidationError.new(
              "header #{name.inspect} cannot be overridden; it is set from the message itself",
            )
          end
          unless value.is_a?(String)
            raise ValidationError.new("header #{name.inspect} must have a string value")
          end

          check_unsafe!(value, "header #{name.inspect}")
          headers[name] = value
        end

        if headers.length > MAX_HEADERS
          raise ValidationError.new("too many custom headers: #{headers.length} (limit #{MAX_HEADERS})")
        end

        headers
      end

      def build_attachments(raw)
        return [] if raw.nil?
        raise ValidationError.new("attachments must be an Array") unless raw.is_a?(Array)

        raw.each_with_index.map do |attachment, index|
          label = "attachments[#{index}]"
          unless attachment.is_a?(Hash)
            raise ValidationError.new("#{label} must be a Hash with filename and content")
          end

          entry = {}
          attachment.each { |key, value| entry[key.to_s] = value }

          # A file path is refused outright rather than opened. An SDK that reads
          # whatever path it is handed is a local-file-disclosure primitive the
          # moment a web handler passes user input into it -- the caller reads
          # their own file and hands us the bytes.
          if entry.key?("path")
            raise ValidationError.new(
              "#{label}: this SDK never opens files. Read the bytes yourself and pass them as content:",
            )
          end

          unknown = entry.keys - ALLOWED_ATTACHMENT_KEYS
          unless unknown.empty?
            raise ValidationError.new("#{label}: unknown key(s) #{unknown.sort.join(', ')}")
          end

          filename = entry["filename"]
          unless filename.is_a?(String) && !filename.strip.empty?
            raise ValidationError.new("#{label} needs a filename")
          end
          check_unsafe!(filename, "#{label} filename")

          content = entry["content"]
          unless content.is_a?(String)
            raise ValidationError.new(
              "#{label} content must be a String of bytes (read the file yourself; " \
              "do not base64-encode it, this SDK does that)",
            )
          end
          raise ValidationError.new("#{label} content is empty") if content.empty?

          built = { "filename" => filename, "content" => base64(content) }

          if entry.key?("content_type")
            content_type = optional_string(entry["content_type"], "#{label} content_type")
            check_unsafe!(content_type, "#{label} content_type")
            built["content_type"] = content_type if content_type
          end

          if entry.key?("content_id")
            content_id = optional_string(entry["content_id"], "#{label} content_id")
            check_unsafe!(content_id, "#{label} content_id")
            built["content_id"] = content_id if content_id
          end

          built
        end
      end

      # Strict base64: no line breaks. The server validates the alphabet by hand
      # and refuses anything outside it rather than silently dropping characters,
      # because a silently mangled invoice is worse than a rejected one -- wrapped
      # output would fail that check.
      def base64(bytes)
        if defined?(::Base64)
          ::Base64.strict_encode64(bytes)
        else
          [bytes].pack("m0")
        end
      end

      # The server truncates an over-long tag. This rejects instead: a tag is an
      # analytics label, and a truncated key that silently stops matching the
      # dashboard query a customer built on it is a bug they will never find.
      # The server truncates tags by JavaScript's `.length`, which counts UTF-16
      # units: an emoji is 2 there and 1 in String#length. Counting the same way
      # keeps "reject, never truncate" true for every tag that gets past here.
      def utf16_length(text)
        text.encode(Encoding::UTF_16LE).bytesize / 2
      rescue EncodingError
        text.length
      end

      def build_tags(raw)
        return {} if raw.nil?
        raise ValidationError.new("tags must be a Hash of strings") unless raw.is_a?(Hash)

        tags = {}
        raw.each do |key, value|
          key = key.to_s
          raise ValidationError.new("a tag key cannot be empty") if key.empty?
          unless value.is_a?(String)
            raise ValidationError.new("tag #{key.inspect} must have a string value")
          end
          if utf16_length(key) > MAX_TAG_KEY_LEN
            raise ValidationError.new("tag key #{key.inspect} is over #{MAX_TAG_KEY_LEN} characters")
          end
          if utf16_length(value) > MAX_TAG_VALUE_LEN
            raise ValidationError.new("tag #{key.inspect} value is over #{MAX_TAG_VALUE_LEN} characters")
          end

          tags[key] = value
        end

        if tags.length > MAX_TAGS
          raise ValidationError.new("too many tags: #{tags.length} (limit #{MAX_TAGS})")
        end

        tags
      end

      def idempotency_key_for(supplied)
        # A caller-supplied key always wins and is never regenerated: they may be
        # deriving it from an order id precisely so that two independent processes
        # cannot both send the receipt.
        return SecureRandom.uuid if supplied.nil?

        unless supplied.is_a?(String) && !supplied.strip.empty?
          raise ValidationError.new("idempotency_key must be a non-empty string")
        end
        if supplied.length > 255
          raise ValidationError.new("idempotency_key must be 255 characters or fewer")
        end

        # It travels as a header, so it gets the same injection check as an address.
        check_unsafe!(supplied, "idempotency_key")
        supplied
      end
    end
  end
end
