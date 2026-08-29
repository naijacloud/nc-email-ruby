# frozen_string_literal: true

# Sending a file.
#
#   export NAIJAMAIL_API_KEY=nmail_live_...
#   ruby -Ilib examples/attachment.rb invoice-1024.pdf you@example.com

require "naijacloud/email"

path      = ARGV[0]
recipient = ARGV[1] || "customer@example.com"

abort "usage: ruby -Ilib examples/attachment.rb <file> [recipient]" if path.nil?

# You read the file, not the SDK.
#
# This is the whole point: an SDK that opens whatever path it is handed becomes a
# local-file-disclosure primitive the moment a web handler passes user input into
# it -- `attachments: [{ path: params[:file] }]` and someone reads /etc/passwd.
# So the gem takes bytes, and refuses a `path:` key outright.
bytes = File.binread(path)

nm = NaijaCloud::Email::Client.new

sent = nm.emails.send_email(
  from: ENV["NAIJAMAIL_FROM"] || "Acme <billing@acme.com>",
  to: recipient,
  subject: "Invoice #1024",
  html: '<p>Your invoice is attached.</p>',
  attachments: [
    {
      filename: File.basename(path),
      # Raw bytes. Do not base64-encode them yourself: the SDK does it, and a
      # caller hand-encoding is a caller getting it subtly wrong.
      content: bytes,
      content_type: "application/pdf",
    },
  ],
)

puts "queued #{sent.id} with #{bytes.bytesize} bytes attached"

# To reference an image inline from the HTML instead, give the attachment a
# content_id and point at it with cid:
#
#   attachments: [{ filename: "logo.png", content: png_bytes,
#                   content_type: "image/png", content_id: "logo" }]
#   html: '<img src="cid:logo">'
