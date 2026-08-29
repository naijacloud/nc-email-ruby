# frozen_string_literal: true

module NaijaCloud
  # The official Ruby SDK for Naijamail, Naija Cloud's transactional email API.
  #
  # Note for anyone editing files in this namespace: `NaijaCloud::Email::Email`
  # is a class (the retrieve response), so inside `module Email` the bare
  # constant `Email` resolves to that class and not to this module. Reach for
  # this module by its full path, as the redaction calls below do.
  module Email
    # Renders a key safe to print. The prefix is kept because it is not secret
    # and it is what makes a leaked key recognisable to a secret scanner; every
    # byte after it is dropped. No length hint, no first-four/last-four: both
    # narrow a brute force, and neither helps a human more than the prefix does.
    def self.redact_key(key)
      return "***" unless key.is_a?(String)

      match = key.match(/\Anmail_(live|test)_/)
      match ? "#{match[0]}***" : "***"
    end
  end
end

require "naijacloud/email/version"
require "naijacloud/email/errors"
require "naijacloud/email/objects"
require "naijacloud/email/http"
require "naijacloud/email/emails"
require "naijacloud/email/webhooks"
require "naijacloud/email/client"
