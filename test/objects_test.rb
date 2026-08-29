# frozen_string_literal: true

require_relative "test_helper"

class ObjectsTest < NaijamailTest
  def test_from_hash_ignores_unknown_keys
    # The control plane ships ahead of the SDKs. A field added there has to be a
    # no-op for a customer pinned to an old gem, not a crash in their handler.
    response = NaijaCloud::Email::SendEmailResponse.from_hash(
      "id" => "m1", "status" => "queued", "region" => "af-west", "cost_kobo" => 250,
    )

    assert_equal "m1", response.id
    assert_equal "queued", response.status
    assert_equal 250, response["cost_kobo"]
  end

  def test_from_hash_survives_a_missing_or_wrong_shaped_body
    [nil, "string", [], 42].each do |input|
      response = NaijaCloud::Email::SendEmailResponse.from_hash(input)
      assert_nil response.id
      assert_equal [], response.rejected
    end

    email = NaijaCloud::Email::Email.from_hash(nil)
    assert_nil email.id
    refute email.opened?
  end

  def test_rejected_recipients
    response = NaijaCloud::Email::SendEmailResponse.from_hash(
      "id" => "m1", "status" => "queued",
      "rejected" => [{ "address" => "x@y.com", "reason" => "suppressed" }],
    )

    assert_equal 1, response.rejected.length
    assert_instance_of NaijaCloud::Email::RejectedRecipient, response.rejected.first
    assert_equal "x@y.com", response.rejected.first.address
    assert_includes response.rejected.first.inspect, "x@y.com"
  end

  def test_to_h_returns_the_raw_body
    raw      = { "id" => "m1", "status" => "queued" }
    response = NaijaCloud::Email::SendEmailResponse.from_hash(raw)

    assert_equal raw, response.to_h
    assert response.raw.frozen?
  end

  def test_message_status_constants
    assert_equal "queued", NaijaCloud::Email::MessageStatus::QUEUED
    assert_equal "delivered", NaijaCloud::Email::MessageStatus::DELIVERED
    assert_equal 8, NaijaCloud::Email::MessageStatus::ALL.length
    assert NaijaCloud::Email::MessageStatus.known?("bounced")
    refute NaijaCloud::Email::MessageStatus.known?("quarantined")
    assert NaijaCloud::Email::MessageStatus::ALL.frozen?
  end

  def test_status_constants_are_frozen_strings
    NaijaCloud::Email::MessageStatus::ALL.each do |status|
      assert status.frozen?, "#{status} should be frozen"
    end
  end

  def test_webhook_event_falls_back_to_data_id
    event = NaijaCloud::Email::WebhookEvent.from_hash(
      "id" => "evt_1", "type" => "email.bounced", "data" => { "id" => "m1" },
    )

    assert_equal "m1", event.email_id
    assert_includes event.inspect, "email.bounced"
  end

  def test_webhook_event_with_no_data
    event = NaijaCloud::Email::WebhookEvent.from_hash("id" => "evt_1", "type" => "email.sent")

    assert_equal({}, event.data)
    assert_nil event.email_id
  end

  def test_email_inspect_is_short
    email = NaijaCloud::Email::Email.from_hash(
      "id" => "m1", "to" => "x@y.com", "status" => "delivered", "subject" => "Receipt",
    )

    assert_includes email.inspect, "m1"
    assert_includes email.inspect, "delivered"
  end
end
