# frozen_string_literal: true

require_relative "test_helper"

class ErrorsTest < NaijamailTest
  def setup
    super
    # Retries off: this file is about the mapping, not the retry policy.
    @client = build_client(max_retries: 0)
  end

  def send_one
    @client.emails.send_email(from: "a@acme.com", to: "b@example.com", subject: "Hi")
  end

  def test_status_to_error_type
    {
      400 => NaijaCloud::Email::ValidationError,
      401 => NaijaCloud::Email::AuthenticationError,
      403 => NaijaCloud::Email::PermissionError,
      404 => NaijaCloud::Email::NotFoundError,
      408 => NaijaCloud::Email::TimeoutError,
      409 => NaijaCloud::Email::ConflictError,
      422 => NaijaCloud::Email::ValidationError,
      429 => NaijaCloud::Email::RateLimitError,
      500 => NaijaCloud::Email::ServerError,
      502 => NaijaCloud::Email::ServerError,
      503 => NaijaCloud::Email::ServerError,
    }.each do |status, klass|
      @server.enqueue(status: status, body: error_body(status, "boom"))

      error = assert_raises(klass, "expected #{status} to raise #{klass}") { send_one }
      assert_equal status, error.status_code
      assert_kind_of NaijaCloud::Email::Error, error
    end
  end

  def test_an_unmapped_4xx_is_the_base_error
    @server.enqueue(status: 418, body: error_body(418, "I'm a teapot"))

    error = assert_raises(NaijaCloud::Email::Error) { send_one }

    assert_equal 418, error.status_code
    assert_equal "I'm a teapot", error.message
  end

  def test_the_test_key_403_carries_the_servers_message
    body = error_body(403, "this is a test key - it cannot send real email. Use a live key.", "Forbidden")
    @server.enqueue(status: 403, body: body)

    error = assert_raises(NaijaCloud::Email::PermissionError) { send_one }

    assert_includes error.message, "test key"
    assert_equal "Forbidden", error.error_label
    refute error.retryable?
  end

  def test_a_message_array_is_joined
    @server.enqueue(status: 400, body: error_body(400, ['"to" is required', "subject must be a string"]))

    error = assert_raises(NaijaCloud::Email::ValidationError) { send_one }

    assert_equal '"to" is required; subject must be a string', error.message
  end

  def test_a_non_json_body_falls_back_to_the_status_line
    # A proxy between the caller and us returning an HTML error page must not
    # surface as JSON::ParserError -- that hides the status code, which is the
    # only thing that would have explained the failure.
    @server.enqueue(status: 502, body: "<html><body>502 Bad Gateway</body></html>",
                    headers: { "Content-Type" => "text/html" })

    error = assert_raises(NaijaCloud::Email::ServerError) { send_one }

    assert_equal 502, error.status_code
    assert_equal "HTTP 502 Bad Gateway", error.message
    assert_equal "<html><body>502 Bad Gateway</body></html>", error.body
  end

  def test_an_empty_body_falls_back_to_the_status_line
    @server.enqueue(status: 500, body: "")

    error = assert_raises(NaijaCloud::Email::ServerError) { send_one }

    assert_equal "HTTP 500 Internal Server Error", error.message
  end

  def test_a_json_body_with_no_message_falls_back_to_the_status_line
    @server.enqueue(status: 503, body: { "error" => "Service Unavailable" })

    error = assert_raises(NaijaCloud::Email::ServerError) { send_one }

    assert_equal "HTTP 503 Service Unavailable", error.message
    assert_equal "Service Unavailable", error.error_label
  end

  def test_a_2xx_that_is_not_json_is_a_server_error
    @server.enqueue(status: 202, body: "not json at all")

    error = assert_raises(NaijaCloud::Email::ServerError) { send_one }

    assert_equal 202, error.status_code
  end

  def test_the_request_id_is_carried
    @server.enqueue(status: 500, body: error_body(500, "boom"), headers: { "X-Request-Id" => "req_abc123" })

    error = assert_raises(NaijaCloud::Email::ServerError) { send_one }

    assert_equal "req_abc123", error.request_id
  end

  def test_rate_limit_carries_retry_after
    @server.enqueue(status: 429, body: error_body(429, "Too many requests"), headers: { "Retry-After" => "7" })

    error = assert_raises(NaijaCloud::Email::RateLimitError) { send_one }

    assert_equal 7.0, error.retry_after
    assert error.retryable?
  end

  def test_a_redirect_is_never_followed
    # net/http does not follow redirects unless the caller writes the loop, so
    # there is nothing to switch off -- but the refusal is made explicit rather
    # than incidental, because following one would re-send the Authorization
    # header to whatever host the response named.
    @server.enqueue(status: 302, body: "", headers: { "Location" => "https://evil.example.com/v1/emails" })

    error = assert_raises(NaijaCloud::Email::ServerError) { send_one }

    assert_equal 302, error.status_code
    assert_includes error.message, "unexpected redirect"
    refute error.retryable?
    assert_equal 1, @server.request_count
  end

  def test_a_301_is_also_refused
    @server.enqueue(status: 301, body: "", headers: { "Location" => "http://evil.example.com/" })

    error = assert_raises(NaijaCloud::Email::ServerError) { send_one }

    assert_includes error.message, "unexpected redirect"
    assert_equal 1, @server.request_count
  end

  def test_a_connection_failure_is_a_connection_error
    client = NaijaCloud::Email::Client.new(
      api_key: TEST_API_KEY, base_url: "http://127.0.0.1:#{closed_port}", max_retries: 0,
    )

    error = assert_raises(NaijaCloud::Email::ConnectionError) do
      client.emails.send_email(from: "a@acme.com", to: "b@example.com", subject: "Hi")
    end

    assert_equal 0, error.status_code
    assert error.retryable?
  end

  def test_a_client_side_deadline_is_a_timeout_error
    @server.enqueue(status: 202, body: { "id" => "m1", "status" => "queued" }, hang: 0.6)
    client = build_client(timeout: 0.15, max_retries: 0)

    error = assert_raises(NaijaCloud::Email::TimeoutError) do
      client.emails.send_email(from: "a@acme.com", to: "b@example.com", subject: "Hi")
    end

    assert_equal 0, error.status_code
    assert error.retryable?
  end

  def test_a_garbage_response_is_a_connection_error
    # A proxy answering with something that is not an HTTP status line must still
    # surface as a NaijaCloud::Email::Error, not as a raw net/http exception.
    @server.enqueue(raw: "not-an-http-response\r\n\r\n")

    error = assert_raises(NaijaCloud::Email::ConnectionError) { send_one }

    assert_equal 0, error.status_code
    assert error.retryable?
  end

  def test_local_errors_carry_status_code_zero
    error = assert_raises(NaijaCloud::Email::ValidationError) { @client.emails.send_email(from: "a@acme.com") }

    assert_equal 0, error.status_code
    refute error.retryable?
  end

  def test_error_inspect_does_not_print_the_body
    # An error body can echo the request: a subject line, a recipient. Printing
    # it by default is how that ends up in a log aggregator.
    @server.enqueue(status: 400, body: error_body(400, "bad", "Bad Request"))

    error = assert_raises(NaijaCloud::Email::ValidationError) { send_one }

    refute_includes error.inspect, "statusCode"
    assert_includes error.inspect, "status_code=400"
  end
end
