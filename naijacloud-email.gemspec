# frozen_string_literal: true

require_relative "lib/naijacloud/email/version"

Gem::Specification.new do |spec|
  spec.name    = "naijacloud-email"
  spec.version = NaijaCloud::Email::VERSION
  spec.authors = ["Naija Cloud"]
  spec.email   = ["support@naijacloud.com"]

  spec.summary     = "Ruby SDK for Naijamail, the Naija Cloud transactional email API."
  spec.description = "Send and retrieve transactional email through the Naijamail API. " \
                     "No runtime dependencies: standard-library net/http only."
  spec.homepage = "https://github.com/naijacloud/nc-email-ruby"
  spec.license  = "MIT"

  # 2.7 is the floor because that is what the oldest supported customer app in
  # our fleet runs. Nothing in this gem needs 3.x syntax, and requiring it would
  # push those apps into a Ruby upgrade to get a security fix in an SDK.
  spec.required_ruby_version = ">= 2.7.0"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "documentation_uri" => "https://naijacloud.com/docs/api/email",
    # This gem is installed into processes that hold live sending keys, so an
    # account takeover on a maintainer would be a supply-chain incident for every
    # customer using it. Publishing requires a second factor.
    "rubygems_mfa_required" => "true",
  }

  spec.files = Dir[
    "lib/**/*.rb",
    "README.md",
    "LICENSE",
    "CHANGELOG.md",
    "SECURITY.md",
    "CONTRIBUTING.md",
  ]
  spec.require_paths = ["lib"]

  # Deliberately no runtime dependencies. Every one would be another maintainer
  # who could ship code into a process that can send mail as a customer's
  # verified domain -- see SECURITY.md.
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
