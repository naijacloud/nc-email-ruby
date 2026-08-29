# frozen_string_literal: true

# The quickstart.
#
#   export NAIJAMAIL_API_KEY=nmail_live_...
#   ruby -Ilib examples/send.rb you@example.com
#
# Nothing here holds a key: it comes from the environment, which is the only
# place it should ever live.

require "naijacloud/email"

recipient = ARGV[0] || "customer@example.com"

# The From domain must be verified for your team -- an unverified one answers
# 403, and no amount of retrying changes that.
sender = ENV["NAIJAMAIL_FROM"] || "Acme <hello@acme.com>"

nm = NaijaCloud::Email::Client.new # reads NAIJAMAIL_API_KEY

sent = nm.emails.send_email(
  from: sender,
  to: recipient,
  subject: "Your receipt",
  html: "<p>Thanks for your order.</p>",
  text: "Thanks for your order.",
  tags: { "campaign" => "receipts" },
)

puts "queued #{sent.id} (#{sent.status})"

# A 202 can still name recipients we refused, because they are on your team's
# suppression list. That is not an error -- the rest of the message went.
sent.rejected.each do |rejected|
  puts "refused #{rejected.address}: #{rejected.reason}"
end

# The send is asynchronous: `queued` means it passed authorisation, suppression,
# reputation and quota checks, not that a mailbox has it. Poll, or wait for a
# webhook once the control plane emits them.
email = nm.emails.get(sent.id)
puts "#{email.id} is #{email.status} (created #{email.created_at})"
