# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-10-07

Conformance pass across the five Naijamail SDKs (TGL-741). Where they had drifted
apart, each now does what the SDK contract settles on.

### Changed

- The 10 MiB limit is measured the way the server measures it: the UTF-8 bytes of
  `html` and `text` plus the raw (decoded) attachment bytes, instead of the whole
  encoded JSON. Attachments between ~7.5 and 10 MiB are no longer refused locally.
- Any unmapped 4xx (405, 415, 451…) raises `ValidationError` instead of the base
  `Error`.
- A `base_url` with a query string or fragment is refused (it used to be kept,
  with every request path appended after it).
- A blank `NAIJAMAIL_BASE_URL` is treated as unset instead of failing
  construction.
- An empty `idempotency_key:` generates one, as if it were omitted, instead of
  raising. The 255 limit is counted in UTF-8 bytes, not characters.
- An `nc_pat_…` key is refused with a message saying it is a personal access
  token and which keys to use, instead of "does not look like a Naijamail key".
- `max_retries` above 10 is refused.
- `timeout` is now a deadline on the whole attempt (connect, send, and reading
  the full response), not a per-socket-read timeout.
- `Webhooks.verify`: a negative or non-numeric `tolerance` raises
  `ValidationError` (`0` remains strict); `t` must be 1–12 ASCII digits.
- Forbidden custom headers are matched on the trimmed name, so `" From"` is
  refused as an override rather than as an invalid name.

### Added

- `Error#raw_body` (the response text, same as `#body`) and `Error#parsed_body`
  (the JSON-decoded body, or `nil`).

### Fixed

- A `http://[::1]` base URL could not connect: Net::HTTP was given the bracketed
  host. It now uses the bare address.
- `Webhooks.verify` accepts upper-case hex signatures.
- `Webhooks.verify` raises on a verified payload that is not a JSON object (an
  array used to come back as an empty event).
- A send response with no `id` raises `ServerError` instead of returning a
  response whose `id` is `nil`.
- Text that is not valid UTF-8 raises `ValidationError` instead of
  `JSON::GeneratorError` or `ArgumentError`.

## [0.2.0] - 2026-10-04

The first version published to RubyGems (`gem install naijacloud-email`).
0.1.0 was written up here but never pushed, so its entries below are part of
this release too.

### Added

- Accept a workspace API key (`nc_live_…`) alongside the Naijamail keys. It is
  the credential from **Settings → API keys**, and it reaches the mail API when
  it carries the **Email send** scope — so a team that already has one for
  deploys and the platform API does not need a second secret to send mail.
  Redaction knows the new prefix, so a dump still shows which kind of credential
  a process is holding. `nc_pat_…` platform tokens remain refused: they predate
  the scope and the API rejects them on the mail routes.
- `Email#sandbox` / `#sandbox?` on a retrieved email: true for a message sent with a test key,
  which is recorded but never delivered, so a simulated bounce can be told from
  a real one.

### Fixed

- `YAML.dump` of a client or its `emails` resource raises instead of writing
  the API key.
- A 413 (request too large) is a `ValidationError`.
- Tag length is counted in UTF-16 units, the way the server counts it.
- Test keys (`nmail_test_…`) are sandboxed by the API, not refused with a 403.
  The README said otherwise.

## 0.1.0 - 2026-08-29 (never published)

First release. Implements the Naijamail SDK contract for Ruby.

### Added

- `NaijaCloud::Email::Client` with `api_key`, `base_url`, `timeout`,
  `max_retries` and `user_agent_suffix`. The key defaults to `NAIJAMAIL_API_KEY`
  and the base URL to `NAIJAMAIL_BASE_URL`, else `https://api.naijacloud.com`.
- `emails.send_email` (aliased `create`) for `POST /v1/emails`, accepting
  keywords or a single Hash.
- `emails.get(id)` for `GET /v1/emails/{id}`.
- Response objects `SendEmailResponse`, `Email`, `RejectedRecipient` and
  `WebhookEvent`, all of which ignore unknown fields so a new server field does
  not break an installed gem. `rejected` is always an array.
- `MessageStatus` constants, with unknown statuses passing through as strings.
- Error hierarchy under `NaijaCloud::Email::Error` carrying `status_code`,
  `error_label`, `request_id` and `body`; `RateLimitError#retry_after`.
- Retries: 3 attempts, full-jitter exponential backoff (500ms base, 8s cap), only
  on 429/408/5xx/connection/timeout, with `Retry-After` honoured in both its
  forms and clamped to 60s.
- An `Idempotency-Key` generated once per send call and reused across that call's
  retries, so a retry after a timeout cannot double-mail.
- `Webhooks.verify` for the `NC-Signature` scheme, with constant-time comparison
  and a 300-second default replay tolerance. Naija Cloud emits these events;
  the scheme is shared with every other Naijamail SDK, so all of them verify
  identically.
- Security enforcement described in SECURITY.md: HTTPS-only base URLs, no
  redirect following, key redaction, header-injection rejection, forbidden
  header names, client-side limits and bytes-only attachments.

[Unreleased]: https://github.com/naijacloud/nc-email-ruby/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/naijacloud/nc-email-ruby/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/naijacloud/nc-email-ruby/releases/tag/v0.2.0
