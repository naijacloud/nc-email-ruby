<p align="center">
  <a href="https://www.naijacloud.com">
    <img alt="Naijamail — Ruby SDK" src="https://raw.githubusercontent.com/naijacloud/nc-email-ruby/main/.github/assets/banner.png" width="100%">
  </a>
</p>

<p align="center">
  <a href="https://rubygems.org/gems/naijacloud-email"><img alt="gem" src="https://img.shields.io/badge/gem-naijacloud--email-008751?style=flat-square&labelColor=0A0E0C"></a>
  <img alt="ruby" src="https://img.shields.io/badge/ruby-%3E%3D_2.7-E0483F?style=flat-square&labelColor=0A0E0C">
  <img alt="dependencies" src="https://img.shields.io/badge/dependencies-0-46C98A?style=flat-square&labelColor=0A0E0C">
  <a href="LICENSE"><img alt="license" src="https://img.shields.io/badge/license-MIT-8A988F?style=flat-square&labelColor=0A0E0C"></a>
</p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="#the-api-surface">The API surface</a> ·
  <a href="#client-options">Client options</a> ·
  <a href="#errors">Errors</a> ·
  <a href="#retries">Retries</a> ·
  <a href="#webhooks">Webhooks</a> ·
  <a href="#security">Security</a>
</p>

# naijacloud-email

The official Ruby SDK for **Naijamail**, the transactional email API of
[Naija Cloud](https://www.naijacloud.com).

Zero runtime dependencies. Standard-library `net/http` only.

```ruby
require "naijacloud/email"

nm = NaijaCloud::Email::Client.new           # reads NAIJAMAIL_API_KEY

sent = nm.emails.send_email(
  from: "Acme <hello@acme.com>",
  to: "customer@example.com",
  subject: "Your receipt",
  html: "<p>Thanks for your order.</p>",
)

puts sent.id                                  # => "5b1e..."
puts sent.status                              # => "queued"

email = nm.emails.get(sent.id)
puts email.status                             # => "delivered"
```

## Install

```ruby
gem "naijacloud-email"
```

Ruby 2.7 or newer.

## The API surface

The control plane has exactly two endpoints, so the SDK has exactly two methods.
There is no `domains`, `api_keys`, `batch` or `contacts` resource: those exist in
other vendors' SDKs and not in ours, because a method that returns 404 for
everyone is worse than no method.

| | |
| --- | --- |
| `nm.emails.send_email(...)` | `POST /v1/emails`, returns `SendEmailResponse` |
| `nm.emails.create(...)` | alias of `send_email` |
| `nm.emails.get(id)` | `GET /v1/emails/{id}`, returns `Email` |
| `NaijaCloud::Email::Webhooks.verify(...)` | verifies a signed webhook delivery |

`send_email`, not `send`: `send` is `Object#send`, and shadowing it on a resource
object means anything that dispatches by name against it — including some mocking
libraries — tries to mail a message instead.

Both call styles work, on every supported Ruby:

```ruby
nm.emails.send_email(from: "...", to: "...", subject: "Hi")
nm.emails.send_email({ from: "...", to: "...", subject: "Hi" })
```

### Send options

| Option | Type | Notes |
| --- | --- | --- |
| `from:` | String | **required.** `"Name <a@b.com>"` or a bare address. The domain must be verified for your team. |
| `to:` | String or Array | **required.** At least one. |
| `cc:`, `bcc:` | String or Array | |
| `reply_to:` | String or Array | Sent on the wire as `reply_to`. |
| `subject:` | String | Always sent; defaults to `""`. |
| `html:`, `text:` | String | |
| `headers:` | Hash | At most 25. `From`, `To`, `Cc`, `Bcc`, `Subject`, `DKIM-Signature` and `Received` are refused. |
| `attachments:` | Array of Hashes | `{ filename:, content:, content_type:, content_id: }` |
| `tags:` | Hash | At most 10, key ≤ 64 chars, value ≤ 256. |
| `idempotency_key:` | String | Optional; one is generated per call if you do not pass one. |

An unknown option raises `ValidationError` rather than being dropped, so
`htlm:` fails on your machine instead of sending a blank email to a customer.

### Attachments

Pass **bytes**, not a path, and do not base64-encode them yourself:

```ruby
nm.emails.send_email(
  from: "Acme <billing@acme.com>",
  to: "customer@example.com",
  subject: "Invoice #1024",
  html: "<p>Attached.</p>",
  attachments: [
    { filename: "invoice-1024.pdf",
      content: File.binread("invoice-1024.pdf"),   # you read the file, not us
      content_type: "application/pdf" },
  ],
)
```

The SDK never opens a file on your behalf. An SDK that reads whatever path it is
handed becomes a local-file-disclosure primitive the moment a web handler passes
user input into it — so you read your own file and hand over the bytes.

### Rejected recipients

A `202` can still name recipients we refused (the suppression list). It is not an
error: the rest of the message went.

```ruby
sent = nm.emails.send_email(...)
sent.rejected.each { |r| puts "#{r.address}: #{r.reason}" }
```

`rejected` is always an array, never `nil`, even though the server omits the key
when it is empty.

### Statuses

`queued`, `sent`, `delivered`, `bounced`, `deferred`, `complained`, `rejected`,
`failed` — as `NaijaCloud::Email::MessageStatus::DELIVERED` and so on. A status
we have not seen before comes through as a plain String rather than raising, so a
new server status does not break an installed gem:

```ruby
NaijaCloud::Email::MessageStatus.known?(email.status)
```

Delivery is not a state machine. A message can go `delivered` and then
`complained`, and providers deliver events out of order often enough that no
client should assume otherwise.

## Client options

```ruby
nm = NaijaCloud::Email::Client.new(
  api_key: ENV["NAIJAMAIL_API_KEY"],   # default: ENV["NAIJAMAIL_API_KEY"]
  base_url: nil,                       # default: ENV["NAIJAMAIL_BASE_URL"] or https://api.naijacloud.com
  timeout: 30,                         # seconds, per attempt
  max_retries: 2,                      # 3 attempts in total
  user_agent_suffix: "acme-billing/2.1",
)
```

Everything lives on the instance. There is no global configuration, so two
clients holding two teams' keys can run in one process without one borrowing the
other's credential.

A client is safe to share across threads: each request opens its own connection
and the client keeps no per-request state.

## Errors

Every failure is a `NaijaCloud::Email::Error`, so one `rescue` covers the lot:

```ruby
begin
  nm.emails.send_email(from: "...", to: "...", subject: "Hi", html: "<p>Hi</p>")
rescue NaijaCloud::Email::PermissionError => e
  # Unverified domain, a test key on the live send path, or a quota.
  warn "#{e.message} (request #{e.request_id})"
rescue NaijaCloud::Email::RateLimitError => e
  warn "rate limited, retry after #{e.retry_after}s"
rescue NaijaCloud::Email::Error => e
  warn "#{e.class}: #{e.message} (HTTP #{e.status_code})"
end
```

| HTTP | Class | Retried |
| --- | --- | --- |
| 400 | `ValidationError` (`NotFoundError` when the message is `message not found`) | no |
| 401 | `AuthenticationError` | no |
| 403 | `PermissionError` | no |
| 404 | `NotFoundError` | no |
| 408 | `TimeoutError` | yes |
| 409 | `ConflictError` | no |
| 422 | `ValidationError` | no |
| 429 | `RateLimitError` (`#retry_after`) | yes |
| 5xx | `ServerError` | yes |
| 3xx | `ServerError` ("unexpected redirect") | no |
| socket / DNS / TLS | `ConnectionError` | yes |
| client-side deadline | `TimeoutError` | yes |
| bad input, caught locally | `ValidationError`, `status_code == 0` | n/a |

Every error carries `message`, `status_code`, `error_label` (the server's short
label), `request_id` (from `x-request-id`) and the raw `body`. Quote the
`request_id` in a support ticket.

A `400` for an id that does not exist is a known control-plane quirk — the
retrieve endpoint raises `BadRequestException('message not found')` instead of a
404. The SDK maps that one case to `NotFoundError`, so your code keeps working
when the server is fixed.

## Retries

Three attempts by default, with full-jitter exponential backoff — `base` 500ms,
`cap` 8s — retried only on `429`, `408`, `5xx`, and connection or timeout
failures. A `Retry-After` header (integer seconds or an HTTP date) overrides the
computed backoff and is clamped to 60 seconds.

A `403` on an unverified domain is never retried. It will not become verified
between two attempts, and retrying only burns your rate limit.

Retrying a `POST` is safe because the SDK generates a UUIDv4 **once per
`send_email` call** and sends it as `Idempotency-Key` on every attempt of that
call. Without it, a timeout followed by a retry mails your customer twice — you
cannot tell "never arrived" from "arrived, response lost". Pass your own
`idempotency_key:` (derived from an order id, say) and it is used verbatim and
never regenerated.

## Security

The full list is in [SECURITY.md](SECURITY.md). In short:

- **HTTPS is enforced** at construction. A plaintext `base_url` is refused unless
  the host is `localhost`, `127.0.0.1` or `::1`.
- **Redirects are never followed.** Following one would re-send your
  `Authorization` header to whatever host the response named.
- **The key is never printed.** `inspect`, `to_s` and any dump of the client's
  instance variables show `nmail_live_***`. The client does not even keep the key
  as one of its own instance variables. There is no verbose mode, because a
  verbose mode is a way to print an `Authorization` header.
- **Header injection is rejected locally** — a `\r`, `\n` or NUL in `from`, any
  address, `subject`, a custom header name or value, or an attachment filename.
- **Limits are checked before the round trip**: 50 recipients, 25 headers, 10
  tags, 10 MiB encoded.
- **Webhook signatures are compared in constant time.**

## Webhooks

> **Live.** Naija Cloud delivers these events to endpoints you register, signed
> exactly as below. Two details this verifier already handles: the timestamp is
> taken per delivery *attempt*, so a retry never arrives outside the tolerance
> window; and during a secret rotation the header carries two `v1=` values for
> 24 hours, which is why any match is accepted.

```ruby
# Rails
class NaijamailWebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token

  def create
    event = NaijaCloud::Email::Webhooks.verify(
      request.raw_post,                       # the RAW body, not params
      request.headers["NC-Signature"],
      ENV.fetch("NAIJAMAIL_WEBHOOK_SECRET"),
    )

    ProcessEmailEvent.perform_later(event.type, event.email_id)
    head :ok
  rescue NaijaCloud::Email::WebhookVerificationError
    head :bad_request
  end
end
```

Pass the raw bytes. A parsed-and-re-serialized body produces different bytes than
the ones that were signed (key order, unicode escaping, whitespace), the
signature then fails for every legitimate delivery, and the usual "fix" for that
is to stop verifying. `Webhooks.verify` refuses a Hash outright for this reason.

Header format: `NC-Signature: t=1756468800,v1=<hex sha256 hmac>`. The signed
payload is `"<t>.<raw body>"`, HMAC-SHA256 with the endpoint secret, hex
lowercase. The default replay tolerance is 300 seconds (`tolerance:`). Several
`v1=` values may appear at once during a secret rotation; any match is accepted.

## Local development against a dev control plane

```ruby
nm = NaijaCloud::Email::Client.new(
  api_key: ENV["NAIJAMAIL_API_KEY"],
  base_url: "http://localhost:3000",
)
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The test suite runs offline against a
mock HTTP server on `127.0.0.1`; it makes no outbound connection.

## License

MIT. Copyright (c) 2026 Naija Cloud.
