# Security

## Reporting a vulnerability

Email **security@naijacloud.com**. Please do not open a public issue, and do not
post a proof of concept anywhere public before we have shipped a fix.

Include what you did, what happened, and the version of the gem. We acknowledge
within two business days (West Africa Time) and will tell you what we intend to
do and by when.

If you have found a **leaked Naijamail key** — in a repository, a log, a
screenshot — treat it as an incident and mail the same address. Revoke it from
the dashboard first: revocation is immediate.

## What this gem does with your key

The API key is a sending credential. A leaked one is a phishing incident on a
domain your customers trust, not an information disclosure, so the gem is built
to keep it in exactly one place.

1. **The key travels only in the `Authorization` header, over TLS.** It is never
   put in a query string, a log line, the User-Agent, or an exception message.
2. **HTTPS is enforced at construction.** A `base_url` whose scheme is not
   `https` is refused unless the host is `localhost`, `127.0.0.1` or `::1`, for
   development against a local control plane. `verify_mode` is set explicitly to
   `OpenSSL::SSL::VERIFY_PEER` rather than inherited from whatever else in the
   process has touched OpenSSL's defaults.
3. **Redirects are never followed.** `net/http` does not follow them on its own,
   and this gem additionally turns any 3xx into a hard `ServerError`. A followed
   redirect re-sends the `Authorization` header to whatever host the response
   names — that is how bearer tokens leak.
4. **The key is redacted everywhere it could be printed.** `Client#inspect` and
   `Client#to_s` show `nmail_live_***`. The client does not keep the key as one
   of its own instance variables — it is handed to the transport, whose `inspect`
   is redacted too — so an error reporter that dumps the receiver's instance
   variables finds nothing. `Marshal.dump` on a client raises rather than writing
   a credential into a file nobody realises is a secret.
5. **There is no verbose or debug mode.** `Net::HTTP#set_debug_output` writes
   every header, `Authorization` included, to whatever IO it is given. The gem
   never calls it and offers no switch that would.
6. **Nothing is global.** Key, base URL and HTTP state live on the client
   instance, so two clients holding two teams' keys cannot interfere.

## What the gem refuses before a request leaves your process

- **Header injection**: `\r`, `\n` or NUL anywhere in `from`, any address in
  `to`/`cc`/`bcc`/`reply_to`, `subject`, a custom header name or value, an
  attachment filename, the idempotency key or the User-Agent suffix. Message
  bodies are exempt: they are content, not headers.
- **Forbidden custom headers**: `From`, `To`, `Cc`, `Bcc`, `Subject`,
  `DKIM-Signature`, `Received`, case-insensitively. Overriding one would sidestep
  the domain authorisation the From address is checked against.
- **Limits**: 50 recipients across to/cc/bcc, 25 custom headers, 10 tags, 10 MiB
  encoded payload.
- **File paths in attachments.** `content:` takes bytes. The gem never opens a
  path, because an SDK that opens whatever path it is handed is a
  local-file-disclosure primitive in a web handler.
- **Message ids** that could alter the request path.
- **Keys of the wrong shape**, so an empty or truncated key fails on your machine
  rather than as a 401 in production an hour after deploy.

## Webhook verification

`Webhooks.verify` compares signatures with `OpenSSL.secure_compare` where it
exists (Ruby 3.0+) and a constant-time XOR comparison otherwise — never `==`,
which stops at the first differing byte and leaks how much of a guess was right.

It signs and verifies the **raw request body**. It refuses a parsed Hash, because
re-serializing produces different bytes than the ones that were signed. The
timestamp is part of the signed payload and is checked against a 300-second
default tolerance, which is what stops a captured delivery being replayed. A
failed verification never returns the expected signature: that would hand an
attacker the answer.

## Supply chain

The gem has **zero runtime dependencies**. Everything is standard library:
`net/http`, `uri`, `json`, `openssl`, `securerandom`, `time`, `base64`.

That is a deliberate cost. This package is installed into processes that hold
live sending keys, so every third-party runtime dependency would be another
maintainer whose account compromise becomes our customers' incident. A faster
HTTP client is not worth that trade. Development and test dependencies (minitest,
rake) are not shipped to users.

Releases require MFA on the RubyGems account (`rubygems_mfa_required`).

## Supported versions

Security fixes are released for the latest minor version. Ruby 2.7 and newer are
supported.
