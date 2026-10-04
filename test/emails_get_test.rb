# frozen_string_literal: true

require_relative "test_helper"

class EmailsGetTest < NaijamailTest
  def setup
    super
    @client = build_client
  end

  def test_retrieve
    @server.enqueue(status: 200, body: {
      "id" => "5b1e0000",
      "to" => "x@y.com",
      "from" => "hello@acme.com",
      "subject" => "Hi",
      "status" => "delivered",
      "created_at" => "2026-08-29T10:00:00.000Z",
      "delivered_at" => "2026-08-29T10:00:04.000Z",
      "opened" => false,
      "clicked" => true,
    })

    email = @client.emails.get("5b1e0000")

    assert_instance_of NaijaCloud::Email::Email, email
    assert_equal "5b1e0000", email.id
    assert_equal "x@y.com", email.to
    assert_equal "hello@acme.com", email.from
    assert_equal "Hi", email.subject
    assert_equal NaijaCloud::Email::MessageStatus::DELIVERED, email.status
    assert email.delivered?
    refute email.opened?
    assert email.clicked?
    assert_nil email.failure_reason

    request = @server.last_request
    assert_equal "GET", request[:method]
    assert_equal "/v1/emails/5b1e0000", request[:path]
    assert_equal "Bearer #{TEST_API_KEY}", request[:headers]["authorization"]
  end

  def test_delivered_at_is_null_until_delivery
    @server.enqueue(status: 200, body: {
      "id" => "m1", "to" => "x@y.com", "from" => "a@acme.com", "subject" => "Hi",
      "status" => "queued", "created_at" => "2026-08-29T10:00:00.000Z",
      "delivered_at" => nil, "opened" => false, "clicked" => false,
    })

    email = @client.emails.get("m1")

    assert_nil email.delivered_at
    assert_nil email.delivered_at_time
    refute email.delivered?
  end

  def test_timestamps_can_be_parsed_on_demand
    @server.enqueue(status: 200, body: {
      "id" => "m1", "to" => "x@y.com", "from" => "a@acme.com", "subject" => "Hi",
      "status" => "delivered", "created_at" => "2026-08-29T10:00:00.000Z",
      "delivered_at" => "2026-08-29T10:00:04.000Z", "opened" => false, "clicked" => false,
    })

    email = @client.emails.get("m1")

    assert_equal "2026-08-29T10:00:00.000Z", email.created_at
    assert_equal Time.utc(2026, 8, 29, 10, 0, 0), email.created_at_time
    assert_equal Time.utc(2026, 8, 29, 10, 0, 4), email.delivered_at_time
  end

  def test_failure_reason_is_exposed_when_present
    @server.enqueue(status: 200, body: {
      "id" => "m1", "to" => "x@y.com", "from" => "a@acme.com", "subject" => "Hi",
      "status" => "bounced", "created_at" => "2026-08-29T10:00:00.000Z",
      "delivered_at" => nil, "opened" => false, "clicked" => false,
      "failure_reason" => "550 5.1.1 unknown recipient",
    })

    email = @client.emails.get("m1")

    assert_equal "550 5.1.1 unknown recipient", email.failure_reason
  end

  def test_unknown_fields_are_ignored_but_readable
    @server.enqueue(status: 200, body: {
      "id" => "m1", "to" => "x@y.com", "from" => "a@acme.com", "subject" => "Hi",
      "status" => "delivered", "created_at" => "2026-08-29T10:00:00.000Z",
      "opened" => false, "clicked" => false, "region" => "af-west",
    })

    email = @client.emails.get("m1")

    assert_equal "m1", email.id
    assert_equal "af-west", email["region"]
  end

  def test_an_unknown_id_returns_not_found_despite_the_400
    # A control-plane quirk: findOne misses and the controller raises
    # BadRequestException('message not found'). Callers get NotFoundError anyway,
    # so their code keeps working when the server starts answering 404.
    @server.enqueue(status: 400, body: error_body(400, "message not found", "Bad Request"))

    error = assert_raises(NaijaCloud::Email::NotFoundError) { @client.emails.get("does-not-exist") }

    assert_equal 400, error.status_code
    assert_equal "message not found", error.message
  end

  def test_a_different_400_is_still_a_validation_error
    @server.enqueue(status: 400, body: error_body(400, "Validation failed (uuid is expected)", "Bad Request"))

    assert_raises(NaijaCloud::Email::ValidationError) { @client.emails.get("nope") }
  end

  def test_an_id_that_could_change_the_path_is_refused_locally
    ["", "../../admin", "..", "a..b", "a/b", "a?b=1", "a b", "a\nb", "a\0b"].each do |id|
      assert_raises(NaijaCloud::Email::ValidationError, "expected #{id.inspect} to be refused") do
        @client.emails.get(id)
      end
    end
    assert_raises(NaijaCloud::Email::ValidationError) { @client.emails.get(nil) }

    assert_equal 0, @server.request_count
  end

  def sandbox_body(extra = {})
    {
      "id" => "1", "to" => "x@y.com", "from" => "a@acme.com", "subject" => "Hi",
      "status" => "bounced", "created_at" => "2026-08-29T10:00:00.000Z",
      "opened" => false, "clicked" => false,
    }.merge(extra)
  end

  def test_exposes_the_sandbox_flag
    # A test-key message is never sent; a "bounced" one is simulated, and
    # without the flag it reads exactly like a real bounce.
    @server.enqueue(status: 200, body: sandbox_body("sandbox" => true))
    email = @client.emails.get("1")
    assert email.sandbox?
    assert_equal true, email.sandbox
  end

  def test_sandbox_defaults_to_false
    @server.enqueue(status: 200, body: sandbox_body)
    refute @client.emails.get("1").sandbox?
  end
end
