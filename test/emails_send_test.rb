# frozen_string_literal: true

require_relative "test_helper"

class EmailsSendTest < NaijamailTest
  def setup
    super
    @client = build_client
  end

  def test_a_successful_send
    @server.enqueue(status: 202, body: { "id" => "5b1e0000", "status" => "queued" })

    sent = @client.emails.send_email(
      from: "Acme <hello@acme.com>",
      to: "customer@example.com",
      subject: "Your receipt",
      html: "<p>Thanks for your order.</p>",
    )

    assert_instance_of NaijaCloud::Email::SendEmailResponse, sent
    assert_equal "5b1e0000", sent.id
    assert_equal NaijaCloud::Email::MessageStatus::QUEUED, sent.status
    assert_equal [], sent.rejected

    request = @server.last_request
    assert_equal "POST", request[:method]
    assert_equal "/v1/emails", request[:path]
    assert_equal "application/json", request[:headers]["content-type"]

    body = json_body(request)
    assert_equal "Acme <hello@acme.com>", body["from"]
    assert_equal ["customer@example.com"], body["to"]
    assert_equal "Your receipt", body["subject"]
    assert_equal "<p>Thanks for your order.</p>", body["html"]
  end

  def test_send_accepts_a_single_hash_argument
    @server.enqueue(status: 202, body: { "id" => "m1", "status" => "queued" })

    sent = @client.emails.send_email(
      { from: "a@acme.com", to: "b@example.com", subject: "Hi", text: "Hi" },
    )

    assert_equal "m1", sent.id
    assert_equal "Hi", json_body(@server.last_request)["text"]
  end

  def test_send_accepts_string_keys
    @server.enqueue(status: 202, body: { "id" => "m1", "status" => "queued" })

    @client.emails.send_email("from" => "a@acme.com", "to" => "b@example.com", "subject" => "Hi")

    assert_equal "Hi", json_body(@server.last_request)["subject"]
  end

  def test_create_is_an_alias_for_send_email
    @server.enqueue(status: 202, body: { "id" => "m1", "status" => "queued" })

    sent = @client.emails.create(from: "a@acme.com", to: "b@example.com", subject: "Hi")

    assert_equal "m1", sent.id
  end

  def test_send_is_not_shadowed
    # Object#send must still dispatch. If the resource defined `send`, this call
    # would try to mail a message named :object_id.
    assert_equal @client.emails.object_id, @client.emails.send(:object_id)
  end

  def test_subject_is_always_sent
    @server.enqueue(status: 202, body: { "id" => "m1", "status" => "queued" })

    @client.emails.send_email(from: "a@acme.com", to: "b@example.com")

    body = json_body(@server.last_request)
    assert body.key?("subject")
    assert_equal "", body["subject"]
  end

  def test_recipient_lists_are_normalised_to_arrays
    @server.enqueue(status: 202, body: { "id" => "m1", "status" => "queued" })

    @client.emails.send_email(
      from: "a@acme.com",
      to: ["one@example.com", "two@example.com"],
      cc: "cc@example.com",
      bcc: ["bcc@example.com"],
      reply_to: "support@acme.com",
      subject: "Hi",
    )

    body = json_body(@server.last_request)
    assert_equal ["one@example.com", "two@example.com"], body["to"]
    assert_equal ["cc@example.com"], body["cc"]
    assert_equal ["bcc@example.com"], body["bcc"]
    assert_equal ["support@acme.com"], body["reply_to"]
    refute body.key?("replyTo")
  end

  def test_reply_to_may_be_given_as_camel_case_but_is_sent_snake_case
    @server.enqueue(status: 202, body: { "id" => "m1", "status" => "queued" })

    @client.emails.send_email(from: "a@acme.com", to: "b@example.com", replyTo: "support@acme.com")

    body = json_body(@server.last_request)
    assert_equal ["support@acme.com"], body["reply_to"]
    refute body.key?("replyTo")
  end

  def test_empty_optional_collections_are_omitted
    @server.enqueue(status: 202, body: { "id" => "m1", "status" => "queued" })

    @client.emails.send_email(from: "a@acme.com", to: "b@example.com", subject: "Hi")

    body = json_body(@server.last_request)
    %w[cc bcc reply_to headers attachments tags html text].each do |key|
      refute body.key?(key), "expected #{key} to be omitted"
    end
  end

  def test_rejected_recipients_are_exposed
    @server.enqueue(status: 202, body: {
      "id" => "m1",
      "status" => "queued",
      "rejected" => [{ "address" => "x@y.com", "reason" => "suppressed" }],
    })

    sent = @client.emails.send_email(from: "a@acme.com", to: ["b@example.com", "x@y.com"], subject: "Hi")

    assert_equal 1, sent.rejected.length
    assert_equal "x@y.com", sent.rejected.first.address
    assert_equal "suppressed", sent.rejected.first.reason
  end

  def test_rejected_is_an_empty_array_when_the_server_omits_it
    # The server sends the key only when it refused someone. Callers must never
    # have to write `sent.rejected&.any?`, and must never read the absent key as
    # a failure -- the rest of the message went.
    @server.enqueue(status: 202, body: { "id" => "m1", "status" => "queued" })

    sent = @client.emails.send_email(from: "a@acme.com", to: "b@example.com", subject: "Hi")

    assert_equal [], sent.rejected
    assert_empty sent.rejected
  end

  def test_rejected_of_an_unexpected_type_still_normalises_to_an_array
    @server.enqueue(status: 202, body: { "id" => "m1", "status" => "queued", "rejected" => nil })

    sent = @client.emails.send_email(from: "a@acme.com", to: "b@example.com", subject: "Hi")

    assert_equal [], sent.rejected
  end

  def test_unknown_response_fields_are_ignored
    @server.enqueue(status: 202, body: {
      "id" => "m1", "status" => "queued", "scheduled_for" => "2027-01-01T00:00:00.000Z",
    })

    sent = @client.emails.send_email(from: "a@acme.com", to: "b@example.com", subject: "Hi")

    assert_equal "m1", sent.id
    assert_equal "2027-01-01T00:00:00.000Z", sent["scheduled_for"]
  end

  def test_an_unknown_status_passes_through
    @server.enqueue(status: 202, body: { "id" => "m1", "status" => "quarantined" })

    sent = @client.emails.send_email(from: "a@acme.com", to: "b@example.com", subject: "Hi")

    assert_equal "quarantined", sent.status
    refute NaijaCloud::Email::MessageStatus.known?(sent.status)
  end

  def test_custom_headers_and_tags_are_sent
    @server.enqueue(status: 202, body: { "id" => "m1", "status" => "queued" })

    @client.emails.send_email(
      from: "a@acme.com",
      to: "b@example.com",
      subject: "Hi",
      headers: { "X-Entity-Ref-ID" => "1024" },
      tags: { "campaign" => "invoices" },
    )

    body = json_body(@server.last_request)
    assert_equal({ "X-Entity-Ref-ID" => "1024" }, body["headers"])
    assert_equal({ "campaign" => "invoices" }, body["tags"])
  end

  def test_attachments_are_base64_encoded_by_the_sdk
    bytes = "%PDF-1.4\n\x00\x01\x02binary".dup.force_encoding(Encoding::BINARY)
    @server.enqueue(status: 202, body: { "id" => "m1", "status" => "queued" })

    @client.emails.send_email(
      from: "a@acme.com",
      to: "b@example.com",
      subject: "Invoice",
      attachments: [{ filename: "invoice.pdf", content: bytes, content_type: "application/pdf" }],
    )

    attachment = json_body(@server.last_request)["attachments"].first
    assert_equal "invoice.pdf", attachment["filename"]
    assert_equal "application/pdf", attachment["content_type"]
    # Strict: no line breaks, and it decodes back to exactly what went in.
    refute_includes attachment["content"], "\n"
    assert_equal bytes, attachment["content"].unpack1("m")
  end

  def test_an_attachment_path_is_refused
    # An SDK that opens whatever path it is handed is a local-file-disclosure
    # primitive the moment a web handler passes user input into it.
    error = assert_raises(NaijaCloud::Email::ValidationError) do
      @client.emails.send_email(
        from: "a@acme.com", to: "b@example.com", subject: "Hi",
        attachments: [{ filename: "secrets", path: "/etc/passwd" }],
      )
    end

    assert_includes error.message, "never opens files"
    assert_equal 0, @server.request_count
  end

  def test_an_unknown_parameter_is_refused_before_the_request
    error = assert_raises(NaijaCloud::Email::ValidationError) do
      @client.emails.send_email(from: "a@acme.com", to: "b@example.com", htlm: "<p>typo</p>")
    end

    assert_includes error.message, "htlm"
    assert_equal 0, @server.request_count
  end

  def test_from_and_to_are_required
    assert_raises(NaijaCloud::Email::ValidationError) { @client.emails.send_email(to: "b@example.com") }
    assert_raises(NaijaCloud::Email::ValidationError) { @client.emails.send_email(from: "a@acme.com") }
    assert_raises(NaijaCloud::Email::ValidationError) do
      @client.emails.send_email(from: "a@acme.com", to: [])
    end
    assert_equal 0, @server.request_count
  end
end
