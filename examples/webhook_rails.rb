# frozen_string_literal: true

# Verifying a Naijamail webhook in Rails.
#
# NOTE: the control plane does not emit customer-facing event webhooks yet. It
# ingests provider webhooks (Mailgun, SES) today. The scheme below is fixed in
# the SDK contract so both halves ship against the same definition -- the
# verifier is real and tested, but nothing is sending you events yet. Do not
# build a production flow on it until the endpoint is announced.
#
# Runnable as a demonstration of the verifier, with no Rails and no network:
#
#   export NAIJAMAIL_WEBHOOK_SECRET=nmail_whsec_...
#   ruby -Ilib examples/webhook_rails.rb

require "naijacloud/email"

# --- The controller ---------------------------------------------------------
#
# Defined only when Rails is present so this file stays runnable on its own.
if defined?(ApplicationController)
  class NaijamailWebhooksController < ApplicationController
    # Naijamail is not a browser and has no CSRF token. The signature is the
    # authentication.
    skip_before_action :verify_authenticity_token

    def create
      event = NaijaCloud::Email::Webhooks.verify(
        # request.raw_post, NOT params. Rails has already parsed the body into
        # params, and re-serializing that produces different bytes than the ones
        # that were signed -- key order, unicode escaping, whitespace. The
        # signature would then fail for every legitimate delivery, and the usual
        # "fix" for that is to stop verifying. Webhooks.verify refuses a Hash
        # outright to make the mistake loud.
        request.raw_post,
        request.headers["NC-Signature"],
        ENV.fetch("NAIJAMAIL_WEBHOOK_SECRET"),
      )

      # Answer immediately and do the work elsewhere. A slow handler is retried
      # by the sender, so slow processing turns into duplicate processing.
      ProcessEmailEventJob.perform_later(event.type, event.email_id)

      head :ok
    rescue NaijaCloud::Email::WebhookVerificationError => e
      # Log the reason, never the expected signature -- returning that would hand
      # an attacker the value they failed to guess.
      Rails.logger.warn("naijamail webhook rejected: #{e.message}")
      head :bad_request
    end
  end

  # config/routes.rb
  #   post "/webhooks/naijamail" => "naijamail_webhooks#create"
end

# --- Local demonstration ----------------------------------------------------

if $PROGRAM_NAME == __FILE__
  require "json"
  require "openssl"

  secret = ENV["NAIJAMAIL_WEBHOOK_SECRET"] || "nmail_whsec_example0000000000000"

  body = JSON.generate(
    "id" => "evt_01J8",
    "type" => "email.delivered",
    "created_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.000Z"),
    "data" => { "email_id" => "5b1e0000-0000-4000-8000-000000000000", "to" => "customer@example.com" },
  )

  # What the sender does: HMAC-SHA256 over "<t>.<raw body>", hex lowercase.
  timestamp = Time.now.to_i
  signature = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{body}")
  header    = "t=#{timestamp},v1=#{signature}"

  event = NaijaCloud::Email::Webhooks.verify(body, header, secret)
  puts "verified #{event.type} for #{event.email_id}"

  # A body altered in transit fails, even though the timestamp is fresh.
  begin
    NaijaCloud::Email::Webhooks.verify(body.sub("customer", "attacker"), header, secret)
  rescue NaijaCloud::Email::WebhookVerificationError => e
    puts "tampered payload rejected: #{e.message}"
  end

  # A captured delivery replayed later fails on the timestamp, which is signed.
  stale_timestamp = Time.now.to_i - 3600
  stale_signature = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{stale_timestamp}.#{body}")
  begin
    NaijaCloud::Email::Webhooks.verify(body, "t=#{stale_timestamp},v1=#{stale_signature}", secret)
  rescue NaijaCloud::Email::WebhookVerificationError => e
    puts "replay rejected: #{e.message}"
  end
end
