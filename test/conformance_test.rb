# frozen_string_literal: true

require_relative "test_helper"

# TGL-741: the points where the five SDKs had drifted apart, each pinned to the
# behaviour the SDK contract now settles on.
class ConformanceTest < NaijamailTest
  MIB = 1024 * 1024

  def setup
    super
    @client = build_client
    @slept  = capture_sleeps(@client)
  end

  def base
    { from: "a@acme.com", to: "b@example.com", subject: "Hi" }
  end

  def send_one(**extra)
    @client.emails.send_email(**base.merge(extra))
  end

  def accepted
    { "id" => "5b1e0000-0000-0000-0000-000000000000", "status" => "queued" }
  end

  def refuses(**params)
    error = assert_raises(NaijaCloud::Email::ValidationError) { send_one(**params) }
    assert_equal 0, @server.request_count, "a request was sent despite the invalid input"
    error
  end

  # -- size: measured like the server -----------------------------------------

  def test_an_attachment_between_7_5_and_10_mib_is_sent
    @server.enqueue(status: 202, body: accepted)
    bytes = ("\x00".b * (9 * MIB))

    send_one(text: "hi", attachments: [{ filename: "big.bin", content: bytes }])

    assert_equal 1, @server.request_count
  end

  def test_the_size_counts_html_text_and_decoded_attachment_bytes
    error = refuses(
      html: "h" * MIB, text: "t" * MIB,
      attachments: [{ filename: "a.bin", content: "\x00".b * (8 * MIB + 1) }],
    )
    assert_includes error.message, "html + text + attachments"
  end

  def test_exactly_ten_mib_is_allowed
    @server.enqueue(status: 202, body: accepted)
    send_one(text: "t" * MIB, attachments: [{ filename: "a.bin", content: "\x00".b * (9 * MIB) }])
    assert_equal 1, @server.request_count
  end

  def test_multibyte_text_is_counted_in_utf8_bytes
    # 5 MiB + 1 characters of a 2-byte letter is over 10 MiB on the wire.
    refuses(text: "é" * (5 * MIB + 1))
  end

  # -- errors -----------------------------------------------------------------

  def test_any_unlisted_4xx_is_a_validation_error_and_not_retried
    [405, 415, 451].each do |status|
      @server.enqueue(status: status, body: error_body(status, "nope"))
      error = assert_raises(NaijaCloud::Email::ValidationError) { send_one }
      assert_equal status, error.status_code
    end
    assert_equal 3, @server.request_count
  end

  def test_errors_expose_the_raw_and_the_parsed_body
    @server.enqueue(status: 403, body: error_body(403, "denied", "Forbidden"))
    error = assert_raises(NaijaCloud::Email::PermissionError) { send_one }

    assert_equal JSON.generate(error_body(403, "denied", "Forbidden")), error.raw_body
    assert_equal error.raw_body, error.body
    assert_equal "denied", error.parsed_body["message"]
  end

  def test_a_non_json_error_has_a_raw_body_and_no_parsed_body
    @server.enqueue(status: 400, body: "<html>bad</html>", headers: { "Content-Type" => "text/html" })
    error = assert_raises(NaijaCloud::Email::ValidationError) { send_one }

    assert_equal "<html>bad</html>", error.raw_body
    assert_nil error.parsed_body
  end

  def test_a_non_json_2xx_is_a_server_error_and_not_retried
    @server.enqueue(status: 202, body: "<html>proxy</html>", headers: { "Content-Type" => "text/html" })
    error = assert_raises(NaijaCloud::Email::ServerError) { send_one }

    assert_includes error.message, "malformed response"
    assert_equal 1, @server.request_count
  end

  def test_a_send_response_without_an_id_is_a_server_error_and_not_retried
    @server.enqueue(status: 202, body: { "status" => "queued" })
    error = assert_raises(NaijaCloud::Email::ServerError) { send_one }

    assert_includes error.message, '"id" is missing'
    assert_equal 1, @server.request_count
    assert_empty @slept
  end

  # -- retries and timeouts -------------------------------------------------------

  def test_retry_after_is_honoured_on_a_503
    @server.enqueue(status: 503, body: error_body(503, "busy"), headers: { "Retry-After" => "7" })
    @server.enqueue(status: 202, body: accepted)

    send_one

    assert_equal [7.0], @slept
  end

  def test_rate_limit_error_retry_after_is_clamped_to_60
    client = build_client(max_retries: 0)
    @server.enqueue(status: 429, body: error_body(429, "slow down"), headers: { "Retry-After" => "3600" })

    error = assert_raises(NaijaCloud::Email::RateLimitError) do
      client.emails.send_email(**base)
    end
    assert_equal 60.0, error.retry_after
  end

  def test_the_timeout_is_a_deadline_on_the_whole_attempt
    client = build_client(timeout: 0.5, max_retries: 0)
    # Each byte arrives well inside the 0.5s per-read timeout; the whole body
    # takes about 4 seconds.
    @server.enqueue(status: 202, body: accepted, trickle: 0.08)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(NaijaCloud::Email::TimeoutError) { client.emails.send_email(**base) }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 2.0
  end

  def test_max_retries_is_capped_at_ten
    assert_equal 10, build_client(max_retries: 10).max_retries
    error = assert_raises(NaijaCloud::Email::ValidationError) { build_client(max_retries: 11) }
    assert_includes error.message, "0 to 10"
  end

  # -- construction ---------------------------------------------------------------

  def test_a_base_url_with_a_query_string_or_fragment_is_refused
    ["https://api.example.com/?region=eu", "https://api.example.com/#x", "http://localhost:1/?a=b"].each do |url|
      error = assert_raises(NaijaCloud::Email::ValidationError, url) do
        NaijaCloud::Email::Client.new(api_key: TEST_API_KEY, base_url: url)
      end
      assert_includes error.message, "query string"
    end
  end

  def test_a_blank_base_url_environment_variable_is_unset
    ["", "   "].each do |blank|
      ENV["NAIJAMAIL_BASE_URL"] = blank
      client = NaijaCloud::Email::Client.new(api_key: TEST_API_KEY)
      assert_equal "https://api.naijacloud.com", client.base_url
    end
  end

  def test_a_personal_access_token_gets_a_specific_message
    pat = "nc_pat_needle0000000000"
    error = assert_raises(NaijaCloud::Email::ValidationError) do
      NaijaCloud::Email::Client.new(api_key: pat)
    end

    assert_equal NaijaCloud::Email::Client::PAT_MESSAGE, error.message
    assert_includes error.message, "personal access token"
    assert_includes error.message, "nc_live_"
    refute_includes error.message, "needle"
  end

  def test_an_ipv6_loopback_base_url_connects
    server =
      begin
        MockServer.new(host: "::1")
      rescue SystemCallError, SocketError
        skip "IPv6 loopback is not available here"
      end

    begin
      server.enqueue(status: 202, body: accepted)
      client = NaijaCloud::Email::Client.new(api_key: TEST_API_KEY, base_url: server.base_url)
      response = client.emails.send_email(**base)

      assert_equal accepted["id"], response.id
      assert_equal 1, server.request_count
    ensure
      server.shutdown
    end
  end

  # -- idempotency ----------------------------------------------------------------

  def test_an_empty_idempotency_key_generates_one
    ["", "  "].each do |blank|
      @server.enqueue(status: 202, body: accepted)
      send_one(idempotency_key: blank)

      key = @server.last_request[:headers]["idempotency-key"]
      assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[0-9a-f]{4}-[0-9a-f]{12}\z/, key)
      refute json_body(@server.last_request).key?("idempotency_key")
    end
  end

  def test_the_idempotency_key_limit_is_counted_in_utf8_bytes
    # 128 characters, 256 bytes.
    refuses(idempotency_key: "é" * 128)

    @server.enqueue(status: 202, body: accepted)
    send_one(idempotency_key: "é" * 127)
    assert_equal 1, @server.request_count
  end

  # -- input that cannot be encoded -------------------------------------------------

  def test_invalid_utf8_is_a_validation_error
    bad = "caf\xE9".dup.force_encoding(Encoding::UTF_8)
    refuses(html: bad)
    refuses(subject: bad)
  end

  # -- attachments and headers ------------------------------------------------------

  def test_attachment_content_type_and_content_id_are_checked_for_injection
    ["\r", "\n", "\0"].each do |injection|
      refuses(attachments: [{ filename: "a.pdf", content: "x", content_type: "text/plain#{injection}X: 1" }])
      refuses(attachments: [{ filename: "a.pdf", content: "x", content_id: "cid#{injection}X: 1" }])
    end
  end

  def test_an_empty_attachment_is_refused
    error = refuses(attachments: [{ filename: "a.pdf", content: "" }])
    assert_includes error.message, "empty"
  end

  def test_a_string_attachment_is_raw_bytes_not_base64
    @server.enqueue(status: 202, body: accepted)
    send_one(text: "x", attachments: [{ filename: "a.txt", content: "aGVsbG8=" }])

    sent = json_body(@server.last_request)["attachments"].first["content"]
    assert_equal "aGVsbG8=", sent.unpack1("m0")
  end

  def test_forbidden_headers_are_matched_on_the_trimmed_name
    [" From", "Bcc\t", "subject ", "\tDKIM-Signature", " received "].each do |name|
      error = refuses(headers: { name => "x" })
      assert_includes error.message, "cannot be overridden", name.inspect
    end
  end

  # -- webhooks ---------------------------------------------------------------------

  SECRET = "nmail_whsec_test0000000000000000"

  def body
    JSON.generate("id" => "evt_1", "type" => "email.delivered", "data" => {})
  end

  def digest(payload, timestamp)
    OpenSSL::HMAC.hexdigest("SHA256", SECRET, "#{timestamp}.#{payload}")
  end

  def verify(payload, header, **opts)
    NaijaCloud::Email::Webhooks.verify(payload, header, SECRET, **opts)
  end

  def test_an_upper_case_hex_signature_is_accepted
    now = Time.now.to_i
    event = verify(body, "t=#{now},v1=#{digest(body, now).upcase}")
    assert_equal "evt_1", event.id
  end

  def test_the_timestamp_must_be_one_to_twelve_ascii_digits
    now = Time.now.to_i
    sig = digest(body, now)
    ["+#{now}", "1_#{now}", "#{now}.0", "1e9", "-#{now}", "", "9" * 13, "9" * 400, "١٢٣"].each do |t|
      assert_raises(NaijaCloud::Email::WebhookVerificationError, t.inspect) do
        verify(body, "t=#{t},v1=#{sig}")
      end
    end
  end

  def test_tolerance_zero_is_strict
    now = Time.now.to_i
    assert_equal "evt_1", verify(body, "t=#{now},v1=#{digest(body, now)}", tolerance: 0).id

    old = now - 5
    assert_raises(NaijaCloud::Email::WebhookVerificationError) do
      verify(body, "t=#{old},v1=#{digest(body, old)}", tolerance: 0)
    end
  end

  def test_a_negative_or_non_numeric_tolerance_is_refused
    now = Time.now.to_i
    header = "t=#{now},v1=#{digest(body, now)}"
    [-1, Float::NAN, Float::INFINITY, "300", nil].each do |tolerance|
      assert_raises(NaijaCloud::Email::ValidationError, tolerance.inspect) do
        verify(body, header, tolerance: tolerance)
      end
    end
  end

  def test_a_payload_that_is_not_a_json_object_is_rejected
    now = Time.now.to_i
    ["[1,2]", "\"evt\"", "42", "null"].each do |payload|
      error = assert_raises(NaijaCloud::Email::WebhookVerificationError, payload) do
        verify(payload, "t=#{now},v1=#{digest(payload, now)}")
      end
      assert_includes error.message, "not a JSON object"
    end
  end
end
