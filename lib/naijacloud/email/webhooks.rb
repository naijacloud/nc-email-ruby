# frozen_string_literal: true

require "openssl"
require "json"
require "time"

module NaijaCloud
  module Email
    # Verifies a signed webhook delivery.
    #
    # The control plane delivers customer-facing event webhooks signed with
    # exactly this scheme (SDK contract section 6).
    module Webhooks
      SIGNATURE_HEADER  = "NC-Signature"
      DEFAULT_TOLERANCE = 300

      class << self
        # payload: the raw request body, exactly as received.
        # signature_header: the value of the NC-Signature header.
        # secret: the endpoint secret (nmail_whsec_...).
        #
        # Returns a WebhookEvent, or raises WebhookVerificationError.
        def verify(payload, signature_header, secret, tolerance: DEFAULT_TOLERANCE)
          # A Hash here is the classic mistake: a framework has already parsed the
          # body, the caller passes the parsed object, and re-serializing it
          # produces different bytes (key order, unicode escaping, whitespace)
          # than the ones that were signed. The signature then fails for every
          # legitimate delivery, and the usual "fix" is to stop verifying.
          unless payload.is_a?(String)
            raise WebhookVerificationError.new(
              "payload must be the raw request body as a String, not a parsed object",
            )
          end
          unless secret.is_a?(String) && !secret.strip.empty?
            raise WebhookVerificationError.new("a webhook signing secret is required")
          end

          # A tolerance that is not a finite, non-negative number would make the
          # replay check meaningless ("abc".to_i is 0, NaN compares false against
          # everything). 0 is strict -- only the current second passes -- and
          # never means "use the default".
          unless tolerance.is_a?(Numeric) && tolerance.real? && tolerance.to_f.finite? && tolerance >= 0
            raise ValidationError.new("tolerance must be a finite number of seconds, 0 or more")
          end

          timestamp, signatures = parse_header(signature_header)

          age = (Time.now.to_i - timestamp).abs
          if age > tolerance
            # This is the whole point of signing the timestamp: without it a
            # captured delivery stays valid forever and can be replayed.
            raise WebhookVerificationError.new(
              "timestamp is #{age}s away from now, outside the #{tolerance}s tolerance",
            )
          end

          # Signed over the raw bytes. Force binary on both halves so a UTF-8
          # body and an ASCII timestamp cannot raise Encoding::CompatibilityError
          # on concatenation.
          signed = "#{timestamp}.".dup.force_encoding(Encoding::BINARY) +
                   payload.dup.force_encoding(Encoding::BINARY)
          expected = OpenSSL::HMAC.hexdigest("SHA256", secret, signed)

          # Several v1 values may be present while a secret is being rotated: the
          # sender signs with both the old and the new secret so neither end has
          # to cut over at an exact instant.
          matched = signatures.any? { |candidate| secure_equal?(expected, candidate) }

          unless matched
            # Never include `expected` in this message. Handing back the
            # signature an attacker failed to guess turns the verifier into an
            # oracle that produces it for them.
            raise WebhookVerificationError.new("signature does not match")
          end

          begin
            parsed = JSON.parse(payload)
          rescue JSON::ParserError => e
            raise WebhookVerificationError.new("signature is valid but the payload is not JSON: #{e.class}")
          end

          # An array, string or number is valid JSON but not an event; turning it
          # into an empty WebhookEvent would hand the caller a blank event they
          # might act on.
          unless parsed.is_a?(Hash)
            raise WebhookVerificationError.new("signature is valid but the payload is not a JSON object")
          end

          WebhookEvent.from_hash(parsed)
        end

        private

        # "t=1756468800,v1=abc,v1=def"
        def parse_header(header)
          unless header.is_a?(String) && !header.strip.empty?
            raise WebhookVerificationError.new("missing #{SIGNATURE_HEADER} header")
          end

          timestamp  = nil
          signatures = []

          header.split(",").each do |part|
            name, value = part.strip.split("=", 2)
            next if value.nil?

            case name
            when "t"  then timestamp = value
            # Hex is case-insensitive; the expected digest is lower-case.
            when "v1" then signatures << value.downcase
            end
          end

          # 1-12 ASCII digits and nothing else (contract section 6): no sign, no
          # underscore, no exponent, and bounded so it can never be a huge
          # Integer.
          unless timestamp.is_a?(String) && timestamp.b =~ /\A[0-9]{1,12}\z/
            raise WebhookVerificationError.new("#{SIGNATURE_HEADER} has no usable timestamp")
          end
          if signatures.empty?
            raise WebhookVerificationError.new("#{SIGNATURE_HEADER} has no v1 signature")
          end

          [timestamp.to_i, signatures]
        end

        # Never `==`. String comparison stops at the first differing byte, so the
        # time it takes leaks how much of a guess was right -- enough, over many
        # requests, to reconstruct a signature a byte at a time.
        #
        # OpenSSL.secure_compare only exists from the openssl gem 2.2 (Ruby 3.0);
        # on 2.7 the fallback below runs, so it is written to be constant time in
        # the length of the compared strings. The length itself is not secret:
        # both sides are a hex SHA-256, always 64 characters.
        def secure_equal?(expected, candidate)
          return false unless candidate.is_a?(String)

          if OpenSSL.respond_to?(:secure_compare)
            OpenSSL.secure_compare(expected, candidate)
          else
            a = expected.b
            b = candidate.b
            return false unless a.bytesize == b.bytesize

            difference = 0
            a.bytes.each_with_index { |byte, index| difference |= byte ^ b.getbyte(index) }
            difference.zero?
          end
        end
      end
    end
  end
end
