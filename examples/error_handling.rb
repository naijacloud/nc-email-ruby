# frozen_string_literal: true

# Every failure this SDK can raise, and what to actually do about each one.
#
#   export NAIJAMAIL_API_KEY=nmail_live_...
#   ruby -Ilib examples/error_handling.rb

require "naijacloud/email"

nm = NaijaCloud::Email::Client.new

begin
  sent = nm.emails.send_email(
    from: ENV["NAIJAMAIL_FROM"] || "Acme <hello@acme.com>",
    to: ARGV[0] || "customer@example.com",
    subject: "Your receipt",
    html: "<p>Thanks for your order.</p>",
  )
  puts "queued #{sent.id}"

# Order matters: rescue the specific classes before the base.
rescue NaijaCloud::Email::ValidationError => e
  # status_code 0 means the SDK refused it locally and nothing was sent -- a bad
  # address, a header with a newline in it, too many recipients. Fix the input;
  # retrying is pointless.
  warn e.status_code.zero? ? "bad input: #{e.message}" : "the API rejected it: #{e.message}"

rescue NaijaCloud::Email::AuthenticationError
  # Missing, malformed, unknown or revoked key. The server deliberately does not
  # say which, so a probe cannot learn which of the four it hit.
  abort "NAIJAMAIL_API_KEY is not a working key"

rescue NaijaCloud::Email::PermissionError => e
  # A test key on the live send path, an unverified From domain, a domain paused
  # for reputation, or the daily quota. None of these get better on a retry, so
  # this belongs in an alert, not a retry loop.
  warn "not allowed: #{e.message}"

rescue NaijaCloud::Email::RateLimitError => e
  # The SDK already retried this up to max_retries, honouring Retry-After. Seeing
  # it here means the limit outlasted the retries: shed load or queue the send.
  warn "still rate limited after #{nm.max_retries} retries; server asked for #{e.retry_after}s"

rescue NaijaCloud::Email::TimeoutError, NaijaCloud::Email::ConnectionError => e
  # Already retried. The message may or may not have been accepted -- which is
  # exactly why the SDK sends the same Idempotency-Key on every attempt. Retry
  # later with your own idempotency_key and the server will dedup it rather than
  # mailing the customer twice.
  warn "could not reach the API: #{e.class}"

rescue NaijaCloud::Email::ServerError => e
  warn "server error #{e.status_code}: #{e.message} (request #{e.request_id})"

rescue NaijaCloud::Email::Error => e
  # One base class catches everything, including a status this version of the SDK
  # has never seen.
  warn "#{e.class}: #{e.message} (HTTP #{e.status_code}, request #{e.request_id})"
end

# Retrieval has one quirk worth handling explicitly: an id that does not exist
# answers 400, not 404. The SDK maps that case to NotFoundError so this rescue
# keeps working when the server is fixed.
begin
  nm.emails.get("00000000-0000-4000-8000-000000000000")
rescue NaijaCloud::Email::NotFoundError
  puts "no such message for this team"
rescue NaijaCloud::Email::Error => e
  warn "#{e.class}: #{e.message}"
end
