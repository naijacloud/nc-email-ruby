# frozen_string_literal: true

module NaijaCloud
  module Email
    # One base class for everything this SDK raises, so a caller can wrap a send
    # in a single `rescue NaijaCloud::Email::Error` and still reach for a
    # specific subclass when it wants to treat one case differently.
    #
    # Failures caught locally (bad input, a plaintext base URL) carry
    # `status_code == 0`: no request left the process, so there is no HTTP status
    # to report and pretending otherwise would send someone hunting through
    # server logs for a request that never arrived.
    class Error < StandardError
      # `body` / `raw_body`: the response text exactly as received (nil for a
      # local error). `parsed_body`: that text decoded as JSON, or nil when it
      # was not JSON. Both are always available, so a caller never has to
      # re-parse or guess which one they were handed.
      attr_reader :status_code, :error_label, :request_id, :body, :parsed_body

      def initialize(message, status_code: 0, error_label: nil, request_id: nil, body: nil,
                     parsed_body: nil, retryable: nil)
        super(message)
        @status_code = status_code
        @error_label = error_label
        @request_id  = request_id
        @body        = body
        @parsed_body = parsed_body
        @retryable   = retryable
      end

      def raw_body
        @body
      end

      # Advisory, for callers that queue their own work. The transport does not
      # consult this: it decides from the HTTP status, because that is the fact
      # on the wire (see Transport#retryable_status?).
      def retryable?
        @retryable.nil? ? self.class.retryable_by_default? : @retryable
      end

      def self.retryable_by_default?
        false
      end

      # Never interpolate the response body here. An error body can echo request
      # content, and an SDK that prints it into a log by default is a way for a
      # subject line or a customer address to end up in a log aggregator.
      def inspect
        "#<#{self.class.name}: #{message.inspect} status_code=#{status_code} " \
          "error_label=#{error_label.inspect} request_id=#{request_id.inspect}>"
      end
    end

    # 400/413/422 and any other unmapped 4xx, and anything the SDK refuses to
    # put on the wire at all.
    class ValidationError < Error; end

    # 401. Missing, malformed, unknown or revoked key -- the server deliberately
    # does not say which, so neither do we.
    class AuthenticationError < Error; end

    # 403. Authenticated but not permitted: a test key on the send path, an
    # unverified From domain, a paused domain, or the daily quota. None of those
    # get better by trying again, which is why 403 is not retryable.
    class PermissionError < Error; end

    # 404, and the 400 the control plane returns for an unknown message id.
    class NotFoundError < Error; end

    # 409.
    class ConflictError < Error; end

    # 429. `retry_after` is seconds, already parsed from either of the two forms
    # the header may take and clamped by the transport before it is slept on.
    class RateLimitError < Error
      attr_reader :retry_after

      def initialize(message, retry_after: nil, **kwargs)
        super(message, **kwargs)
        @retry_after = retry_after
      end

      def self.retryable_by_default?
        true
      end
    end

    # 5xx, plus the deliberate refusal to follow a 3xx.
    class ServerError < Error
      def self.retryable_by_default?
        true
      end
    end

    # Socket, DNS or TLS failure -- the request may or may not have been seen by
    # the server, which is exactly why every send carries an idempotency key.
    class ConnectionError < Error
      def self.retryable_by_default?
        true
      end
    end

    # A client-side deadline, or the server's own 408.
    class TimeoutError < Error
      def self.retryable_by_default?
        true
      end
    end

    # Raised by Webhooks.verify. Deliberately says nothing about *why* beyond a
    # coarse reason: telling a caller "expected abc123" hands an attacker the
    # answer they were trying to guess.
    class WebhookVerificationError < Error; end
  end
end
