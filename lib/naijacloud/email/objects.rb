# frozen_string_literal: true

module NaijaCloud
  module Email
    # The statuses the API uses today, lowercase exactly as they appear on the
    # wire. Frozen constants rather than symbols so a comparison against a value
    # decoded from JSON needs no conversion at the call site.
    #
    # Deliberately NOT an exhaustive enum in the type sense: `Email#status` hands
    # back whatever the server sent. A status added server-side must reach a
    # caller running last year's gem as a plain string, not as a crash -- the
    # alternative is that shipping a new event type breaks every old SDK at once.
    module MessageStatus
      QUEUED     = "queued"
      SENT       = "sent"
      DELIVERED  = "delivered"
      BOUNCED    = "bounced"
      DEFERRED   = "deferred"
      COMPLAINED = "complained"
      REJECTED   = "rejected"
      FAILED     = "failed"

      ALL = [QUEUED, SENT, DELIVERED, BOUNCED, DEFERRED, COMPLAINED, REJECTED, FAILED].freeze

      # For callers that want to branch on "something I have never seen" rather
      # than assume the list above is closed.
      def self.known?(status)
        ALL.include?(status)
      end
    end

    # Base for the response objects. Named BaseObject rather than Object because
    # a class called Object inside this namespace would shadow ::Object for every
    # other file in the gem -- a subtle way to break `is_a?(Object)` checks and
    # anything that rescues on a bare constant.
    #
    # `from_hash` ignores keys it does not know on purpose. The control plane
    # ships ahead of the SDKs, so a field added there must be a no-op for a
    # customer pinned to an old gem version, not a NoMethodError in their
    # webhook handler at 3am. `#raw` keeps the full body so that customer can
    # still read a new field before we cut a release.
    class BaseObject
      attr_reader :raw

      def initialize(raw = {})
        @raw = raw.freeze
      end

      def to_h
        @raw
      end

      # Hash access to the decoded body, for fields this version predates.
      def [](key)
        @raw[key.to_s]
      end
    end

    # A recipient the server refused before sending -- today only because the
    # address is on the team's suppression list.
    class RejectedRecipient < BaseObject
      attr_reader :address, :reason

      def self.from_hash(hash)
        hash = {} unless hash.is_a?(::Hash)
        new(hash)
      end

      def initialize(raw = {})
        super
        @address = raw["address"]
        @reason  = raw["reason"]
      end

      def inspect
        "#<NaijaCloud::Email::RejectedRecipient address=#{address.inspect} reason=#{reason.inspect}>"
      end
    end

    # The 202 body from POST /v1/emails.
    class SendEmailResponse < BaseObject
      attr_reader :id, :status, :rejected

      def self.from_hash(hash)
        hash = {} unless hash.is_a?(::Hash)
        new(hash)
      end

      def initialize(raw = {})
        super
        @id     = raw["id"]
        @status = raw["status"]
        # The server omits `rejected` entirely when nobody was refused. Normalise
        # to an empty array so callers write `if resp.rejected.any?` and never
        # `resp.rejected&.any?` -- and so nobody reads the absent key as an error.
        rejected = raw["rejected"]
        @rejected = (rejected.is_a?(::Array) ? rejected : []).map { |r| RejectedRecipient.from_hash(r) }.freeze
      end

      def inspect
        "#<NaijaCloud::Email::SendEmailResponse id=#{id.inspect} status=#{status.inspect} " \
          "rejected=#{rejected.length}>"
      end
    end

    # The body from GET /v1/emails/{id}.
    #
    # `to` is a single address, not a list: the server writes one row per primary
    # recipient, so a three-recipient send produces three of these and the id you
    # got back from the send is the first of them.
    class Email < BaseObject
      attr_reader :id, :to, :from, :subject, :status, :created_at, :delivered_at,
                  :opened, :clicked, :failure_reason

      def self.from_hash(hash)
        hash = {} unless hash.is_a?(::Hash)
        new(hash)
      end

      def initialize(raw = {})
        super
        @id             = raw["id"]
        @to             = raw["to"]
        @from           = raw["from"]
        @subject        = raw["subject"]
        @status         = raw["status"]
        @created_at     = raw["created_at"]
        @delivered_at   = raw["delivered_at"]
        @opened         = raw["opened"]
        @clicked        = raw["clicked"]
        # Present only on a failure, so its absence is the normal case.
        @failure_reason = raw["failure_reason"]
      end

      def opened?
        !!@opened
      end

      def clicked?
        !!@clicked
      end

      def delivered?
        @status == MessageStatus::DELIVERED
      end

      # Timestamps are left as the ISO-8601 strings the server sent. Parsing them
      # into Time here would force a timezone interpretation on a caller who may
      # only want to pass the value through, and Time.iso8601 raises on anything
      # unexpected -- a parse failure is not worth turning a readable field into
      # an exception.
      def created_at_time
        @created_at && ::Time.iso8601(@created_at)
      end

      def delivered_at_time
        @delivered_at && ::Time.iso8601(@delivered_at)
      end

      def inspect
        "#<NaijaCloud::Email::Email id=#{id.inspect} status=#{status.inspect} to=#{to.inspect}>"
      end
    end

    # A verified webhook delivery.
    #
    # The envelope (id / type / created_at / data) is fixed by the SDK contract
    # section 6; the control plane does not emit these yet, so treat the fields
    # inside `data` as provisional and read anything else through `#raw`.
    class WebhookEvent < BaseObject
      attr_reader :id, :type, :created_at, :data

      def self.from_hash(hash)
        hash = {} unless hash.is_a?(::Hash)
        new(hash)
      end

      def initialize(raw = {})
        super
        @id         = raw["id"]
        @type       = raw["type"]
        @created_at = raw["created_at"]
        @data       = raw["data"].is_a?(::Hash) ? raw["data"].freeze : {}.freeze
      end

      # The message id the event is about, when the event carries one.
      def email_id
        @data["email_id"] || @data["id"]
      end

      def inspect
        "#<NaijaCloud::Email::WebhookEvent id=#{id.inspect} type=#{type.inspect}>"
      end
    end
  end
end
