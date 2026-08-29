# Contributing

## Setup

Nothing to install. The gem has no runtime dependencies, and minitest and rake
ship with Ruby.

```sh
rake test
```

or, without bundler or rake at all:

```sh
ruby -Ilib -Itest test/emails_send_test.rb
```

`bundle install` is only needed if you want a lockfile; the `Gemfile` exists so
`bundle exec rake test` works, not because anything requires it.

## Tests

The suite runs **offline**. `test/test_helper.rb` starts a small HTTP server on
`127.0.0.1` with an ephemeral port, built on raw `TCPServer` — webrick left the
standard library in Ruby 3.0, so building on it would mean a fresh checkout
could not be tested without a network. There is no WebMock and no VCR, and no
test makes an outbound connection.

Scripting a response:

```ruby
@server.enqueue(status: 429, body: { "statusCode" => 429, "message" => "Too many requests" },
                headers: { "Retry-After" => "3" })
@server.enqueue(status: 202, body: { "id" => "m1", "status" => "queued" })
```

`hang:` holds a connection open without answering, which is how the client-side
deadline is tested without waiting out the 30-second default.

Retry timing is asserted, not slept through: `capture_sleeps(client)` replaces
the transport's `sleeper` and pins its `jitter` at the ceiling, and returns the
array of intervals that would have been slept.

**Never commit a real key.** Tests use the literal
`nmail_live_test0000000000000000`, which is the value nominated by the SDK
contract and has never been a real key.

## What to keep in mind when changing this gem

- **The SDK contract is binding.** `email-sdks/spec/SDK-CONTRACT.md` is the same
  document every other Naijamail SDK implements, so a behaviour change here is a
  change to all of them. If the contract and the control plane disagree, the
  control plane wins and the contract gets fixed.
- **Do not invent endpoints.** The server has two: `POST /v1/emails` and
  `GET /v1/emails/{id}`.
- **Zero runtime dependencies.** See SECURITY.md for why this is not negotiable.
- **Every rule in section 5 of the contract is a security rule.** Loosening one
  needs a reason written down, not a commit message saying "simplify".
- **Ruby 2.7 is the floor.** No endless method definitions, no `Data.define`, no
  rightward assignment, no `Hash#except`. CI runs 2.7, 3.0, 3.2 and 3.3.

## House style

Comments explain **why** — the decision, the failure it prevents, the trap it
avoids. A comment that restates the code is noise and will be asked about in
review. `# frozen_string_literal: true` at the top of every file.

## Releasing

1. Update `lib/naijacloud/email/version.rb`.
2. Add a `CHANGELOG.md` entry (Keep a Changelog).
3. `gem build naijacloud-email.gemspec`
4. `gem push naijacloud-email-<version>.gem` (MFA required).
