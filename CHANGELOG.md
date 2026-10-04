# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

## [0.1.0] - 2026-08-29

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

[Unreleased]: https://github.com/naijacloud/nc-email-ruby/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/naijacloud/nc-email-ruby/releases/tag/v0.1.0
