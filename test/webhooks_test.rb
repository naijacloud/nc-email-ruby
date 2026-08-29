# frozen_string_literal: true

require_relative "test_helper"

class WebhooksTest < NaijamailTest
  SECRET = "nmail_whsec_test0000000000000000"

  def payload(overrides = {})
    JSON.generate({
      "id" => "evt_123",
      "type" => "email.delivered",
      "created_at" => "2026-08-29T10:00:04.000Z",
      "data" => { "email_id" => "5b1e0000", "to" => "x@y.com" },
    }.merge(overrides))
  end

  def sign(body, secret: SECRET, timestamp: Time.now.to_i)
    digest = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{body}")
    "t=#{timestamp},v1=#{digest}"
  end

  def test_a_valid_signature_is_accepted
    body  = payload
    event = NaijaCloud::Email::Webhooks.verify(body, sign(body), SECRET)

    assert_instance_of NaijaCloud::Email::WebhookEvent, event
    assert_equal "evt_123", event.id
    assert_equal "email.delivered", event.type
    assert_equal "5b1e0000", event.email_id
    assert_equal "x@y.com", event.data["to"]
  end

  def test_a_wrong_signature_is_rejected
    body = payload

    error = assert_raises(NaijaCloud::Email::WebhookVerificationError) do
      NaijaCloud::Email::Webhooks.verify(body, "t=#{Time.now.to_i},v1=#{'a' * 64}", SECRET)
    end

    assert_includes error.message, "does not match"
  end

  def test_the_expected_signature_is_never_returned_in_the_error
    # Handing back the value an attacker failed to guess turns the verifier into
    # an oracle that produces it for them.
    body     = payload
    expected = OpenSSL::HMAC.hexdigest("SHA256", SECRET, "#{Time.now.to_i}.#{body}")

    error = assert_raises(NaijaCloud::Email::WebhookVerificationError) do
      NaijaCloud::Email::Webhooks.verify(body, "t=#{Time.now.to_i},v1=#{'a' * 64}", SECRET)
    end

    refute_includes error.message, expected
    refute_includes error.message, SECRET
  end

  def test_a_tampered_body_is_rejected
    body      = payload
    signature = sign(body)
    tampered  = body.sub("x@y.com", "attacker@evil.com")

    assert_raises(NaijaCloud::Email::WebhookVerificationError) do
      NaijaCloud::Email::Webhooks.verify(tampered, signature, SECRET)
    end
  end

  def test_the_wrong_secret_is_rejected
    body = payload

    assert_raises(NaijaCloud::Email::WebhookVerificationError) do
      NaijaCloud::Email::Webhooks.verify(body, sign(body), "nmail_whsec_someone_elses_secret")
    end
  end

  def test_a_stale_timestamp_is_rejected
    body = payload
    old  = Time.now.to_i - 301

    error = assert_raises(NaijaCloud::Email::WebhookVerificationError) do
      NaijaCloud::Email::Webhooks.verify(body, sign(body, timestamp: old), SECRET)
    end

    assert_includes error.message, "tolerance"
  end

  def test_a_timestamp_far_in_the_future_is_rejected
    body   = payload
    future = Time.now.to_i + 301

    assert_raises(NaijaCloud::Email::WebhookVerificationError) do
      NaijaCloud::Email::Webhooks.verify(body, sign(body, timestamp: future), SECRET)
    end
  end

  def test_the_tolerance_is_configurable
    body = payload
    old  = Time.now.to_i - 400

    event = NaijaCloud::Email::Webhooks.verify(body, sign(body, timestamp: old), SECRET, tolerance: 600)

    assert_equal "evt_123", event.id
  end

  def test_the_signature_covers_the_timestamp
    # Signing only the body would let a captured delivery be replayed forever by
    # swapping in a fresh t.
    body      = payload
    signature = sign(body, timestamp: Time.now.to_i - 100)
    moved     = signature.sub(/\At=\d+/, "t=#{Time.now.to_i}")

    assert_raises(NaijaCloud::Email::WebhookVerificationError) do
      NaijaCloud::Email::Webhooks.verify(body, moved, SECRET)
    end
  end

  def test_several_v1_values_are_accepted_during_a_rotation
    body      = payload
    timestamp = Time.now.to_i
    good      = OpenSSL::HMAC.hexdigest("SHA256", SECRET, "#{timestamp}.#{body}")
    header    = "t=#{timestamp},v1=#{'b' * 64},v1=#{good}"

    event = NaijaCloud::Email::Webhooks.verify(body, header, SECRET)

    assert_equal "evt_123", event.id
  end

  def test_a_malformed_header_is_rejected
    body = payload

    ["", "   ", "nonsense", "v1=abc", "t=,v1=abc", "t=#{Time.now.to_i}", "t=abc,v1=def"].each do |header|
      assert_raises(NaijaCloud::Email::WebhookVerificationError, "expected #{header.inspect} to be rejected") do
        NaijaCloud::Email::Webhooks.verify(body, header, SECRET)
      end
    end

    assert_raises(NaijaCloud::Email::WebhookVerificationError) do
      NaijaCloud::Email::Webhooks.verify(body, nil, SECRET)
    end
  end

  def test_a_parsed_payload_is_refused
    # Re-serializing a parsed body produces different bytes than the ones that
    # were signed, so this would fail for every legitimate delivery -- and the
    # usual "fix" for that is to stop verifying.
    error = assert_raises(NaijaCloud::Email::WebhookVerificationError) do
      NaijaCloud::Email::Webhooks.verify({ "id" => "evt_123" }, "t=1,v1=abc", SECRET)
    end

    assert_includes error.message, "raw request body"
  end

  def test_a_missing_secret_is_refused
    body = payload

    assert_raises(NaijaCloud::Email::WebhookVerificationError) do
      NaijaCloud::Email::Webhooks.verify(body, sign(body), "")
    end
    assert_raises(NaijaCloud::Email::WebhookVerificationError) do
      NaijaCloud::Email::Webhooks.verify(body, sign(body), nil)
    end
  end

  def test_a_utf8_body_verifies
    body = JSON.generate("id" => "evt_1", "type" => "email.delivered",
                         "data" => { "subject" => "Ẹ ku àárọ̀ — ₦12,500" })

    event = NaijaCloud::Email::Webhooks.verify(body, sign(body), SECRET)

    assert_equal "evt_1", event.id
  end

  def test_a_binary_body_verifies
    body      = payload.dup.force_encoding(Encoding::BINARY)
    signature = sign(body)

    assert_equal "evt_123", NaijaCloud::Email::Webhooks.verify(body, signature, SECRET).id
  end

  def test_a_valid_signature_over_a_non_json_body_is_reported_clearly
    body = "this is not json"

    error = assert_raises(NaijaCloud::Email::WebhookVerificationError) do
      NaijaCloud::Email::Webhooks.verify(body, sign(body), SECRET)
    end

    assert_includes error.message, "not JSON"
  end

  def test_an_event_of_an_unknown_type_still_parses
    body  = payload("type" => "email.something_new")
    event = NaijaCloud::Email::Webhooks.verify(body, sign(body), SECRET)

    assert_equal "email.something_new", event.type
  end
end
