# frozen_string_literal: true

require_relative "test_helper"

class RetryTest < NaijamailTest
  def setup
    super
    @client = build_client
    @slept  = capture_sleeps(@client)
  end

  def send_one(**extra)
    @client.emails.send_email(
      **{ from: "a@acme.com", to: "b@example.com", subject: "Hi" }.merge(extra),
    )
  end

  def test_three_attempts_by_default
    @server.enqueue(status: 500, body: error_body(500, "boom"))
    @server.enqueue(status: 500, body: error_body(500, "boom"))
    @server.enqueue(status: 202, body: { "id" => "m1", "status" => "queued" })

    sent = send_one

    assert_equal "m1", sent.id
    assert_equal 3, @server.request_count
    assert_equal 2, @slept.length
  end

  def test_it_gives_up_after_max_retries
    4.times { @server.enqueue(status: 503, body: error_body(503, "unavailable")) }

    assert_raises(NaijaCloud::Email::ServerError) { send_one }

    # 1 try + 2 retries, not 4.
    assert_equal 3, @server.request_count
  end

  def test_backoff_is_exponential_and_capped
    # capture_sleeps pins the jitter at its ceiling, so this asserts the
    # schedule: base 500ms doubling per attempt, capped at 8s.
    client = build_client(max_retries: 6)
    slept  = capture_sleeps(client)
    7.times { @server.enqueue(status: 500, body: error_body(500, "boom")) }

    assert_raises(NaijaCloud::Email::ServerError) do
      client.emails.send_email(from: "a@acme.com", to: "b@example.com", subject: "Hi")
    end

    assert_equal [0.5, 1.0, 2.0, 4.0, 8.0, 8.0], slept
  end

  def test_jitter_stays_inside_the_ceiling
    # The real jitter, not the pinned one: full jitter means anywhere in
    # [0, ceiling), never the ceiling every time -- clients sleeping in lockstep
    # rebuild the herd that caused the 429.
    client    = build_client(max_retries: 1)
    transport = client.instance_variable_get(:@http)
    slept     = []
    transport.sleeper = ->(seconds) { slept << seconds }

    2.times { @server.enqueue(status: 500, body: error_body(500, "boom")) }
    assert_raises(NaijaCloud::Email::ServerError) do
      client.emails.send_email(from: "a@acme.com", to: "b@example.com", subject: "Hi")
    end

    assert_equal 1, slept.length
    assert_operator slept.first, :>=, 0
    assert_operator slept.first, :<=, 0.5
  end

  def test_retry_after_as_integer_seconds_overrides_the_backoff
    @server.enqueue(status: 429, body: error_body(429, "Too many requests"), headers: { "Retry-After" => "3" })
    @server.enqueue(status: 202, body: { "id" => "m1", "status" => "queued" })

    sent = send_one

    assert_equal "m1", sent.id
    assert_equal [3.0], @slept
  end

  def test_retry_after_as_an_http_date
    when_to_retry = (Time.now + 12).httpdate
    @server.enqueue(status: 429, body: error_body(429, "Too many requests"),
                    headers: { "Retry-After" => when_to_retry })
    @server.enqueue(status: 202, body: { "id" => "m1", "status" => "queued" })

    send_one

    assert_equal 1, @slept.length
    # Allow for the second or so that elapses between building the header and
    # the client parsing it.
    assert_in_delta 12.0, @slept.first, 2.0
  end

  def test_retry_after_is_clamped
    # A server asking for an hour is a misconfiguration; a caller blocked for an
    # hour inside a web request is an outage.
    @server.enqueue(status: 429, body: error_body(429, "Too many requests"),
                    headers: { "Retry-After" => "3600" })
    @server.enqueue(status: 202, body: { "id" => "m1", "status" => "queued" })

    send_one

    assert_equal [60.0], @slept
  end

  def test_a_retry_after_in_the_past_becomes_zero
    @server.enqueue(status: 429, body: error_body(429, "Too many requests"),
                    headers: { "Retry-After" => (Time.now - 30).httpdate })
    @server.enqueue(status: 202, body: { "id" => "m1", "status" => "queued" })

    send_one

    assert_equal [0.0], @slept
  end

  def test_an_unparseable_retry_after_falls_back_to_the_backoff
    @server.enqueue(status: 429, body: error_body(429, "Too many requests"),
                    headers: { "Retry-After" => "soon" })
    @server.enqueue(status: 202, body: { "id" => "m1", "status" => "queued" })

    send_one

    assert_equal [0.5], @slept
  end

  def test_408_is_retried
    @server.enqueue(status: 408, body: error_body(408, "Request Timeout"))
    @server.enqueue(status: 202, body: { "id" => "m1", "status" => "queued" })

    assert_equal "m1", send_one.id
    assert_equal 2, @server.request_count
  end

  def test_no_retry_on_400
    @server.enqueue(status: 400, body: error_body(400, '"to" is required'))

    assert_raises(NaijaCloud::Email::ValidationError) { send_one }

    assert_equal 1, @server.request_count
    assert_empty @slept
  end

  def test_no_retry_on_403
    # An unverified domain will not become verified between two attempts, and
    # retrying a 403 only burns the rate limit.
    @server.enqueue(status: 403, body: error_body(403, 'not allowed to send from "x@y.com".'))

    assert_raises(NaijaCloud::Email::PermissionError) { send_one }

    assert_equal 1, @server.request_count
  end

  def test_no_retry_on_401_404_409_422
    {
      401 => NaijaCloud::Email::AuthenticationError,
      404 => NaijaCloud::Email::NotFoundError,
      409 => NaijaCloud::Email::ConflictError,
      422 => NaijaCloud::Email::ValidationError,
    }.each do |status, klass|
      server = @server
      before = server.request_count
      server.enqueue(status: status, body: error_body(status, "no"))

      assert_raises(klass) { send_one }
      assert_equal before + 1, server.request_count
    end
  end

  def test_a_connection_failure_is_retried
    client = NaijaCloud::Email::Client.new(api_key: TEST_API_KEY, base_url: "http://127.0.0.1:#{closed_port}")
    slept  = capture_sleeps(client)

    assert_raises(NaijaCloud::Email::ConnectionError) do
      client.emails.send_email(from: "a@acme.com", to: "b@example.com", subject: "Hi")
    end

    assert_equal 2, slept.length
  end

  def test_a_client_side_timeout_is_retried
    3.times { @server.enqueue(status: 202, body: { "id" => "m1", "status" => "queued" }, hang: 0.6) }
    client = build_client(timeout: 0.15)
    slept  = capture_sleeps(client)

    assert_raises(NaijaCloud::Email::TimeoutError) do
      client.emails.send_email(from: "a@acme.com", to: "b@example.com", subject: "Hi")
    end

    assert_equal 3, @server.request_count
    assert_equal 2, slept.length
  end

  def test_the_auto_idempotency_key_is_identical_across_every_attempt
    # This is what makes retrying a POST safe. Without it, a timeout followed by
    # a retry mails the customer twice.
    @server.enqueue(status: 500, body: error_body(500, "boom"))
    @server.enqueue(status: 429, body: error_body(429, "slow down"), headers: { "Retry-After" => "0" })
    @server.enqueue(status: 202, body: { "id" => "m1", "status" => "queued" })

    send_one

    keys = @server.requests.map { |request| request[:headers]["idempotency-key"] }

    assert_equal 3, keys.length
    assert_equal 1, keys.uniq.length
    refute_nil keys.first
    assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/, keys.first)
  end

  def test_two_calls_get_different_idempotency_keys
    2.times { @server.enqueue(status: 202, body: { "id" => "m1", "status" => "queued" }) }

    send_one
    send_one

    keys = @server.requests.map { |request| request[:headers]["idempotency-key"] }

    assert_equal 2, keys.uniq.length
  end

  def test_a_caller_supplied_idempotency_key_wins_and_is_never_regenerated
    @server.enqueue(status: 500, body: error_body(500, "boom"))
    @server.enqueue(status: 202, body: { "id" => "m1", "status" => "queued" })

    send_one(idempotency_key: "order-1024")

    keys = @server.requests.map { |request| request[:headers]["idempotency-key"] }

    assert_equal %w[order-1024 order-1024], keys
    # It travels as a header, so it is not repeated in the body where the two
    # could disagree.
    refute json_body(@server.last_request).key?("idempotency_key")
  end

  def test_an_idempotency_key_with_a_line_break_is_refused
    assert_raises(NaijaCloud::Email::ValidationError) { send_one(idempotency_key: "a\r\nX-Evil: 1") }
    assert_raises(NaijaCloud::Email::ValidationError) { send_one(idempotency_key: "x" * 256) }

    assert_equal 0, @server.request_count
  end

  def test_max_retries_zero_means_one_attempt
    client = build_client(max_retries: 0)
    @server.enqueue(status: 500, body: error_body(500, "boom"))

    assert_raises(NaijaCloud::Email::ServerError) do
      client.emails.send_email(from: "a@acme.com", to: "b@example.com", subject: "Hi")
    end

    assert_equal 1, @server.request_count
  end
end
