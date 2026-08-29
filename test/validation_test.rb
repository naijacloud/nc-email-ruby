# frozen_string_literal: true

require_relative "test_helper"

# Section 5 of the SDK contract: everything the SDK refuses before a byte
# reaches the network. Every test here also asserts the request count is zero --
# a check that fails after the request has gone out is not a check.
class ValidationTest < NaijamailTest
  INJECTIONS = ["\r", "\n", "\r\n", "\0"].freeze

  def setup
    super
    @client = build_client
  end

  def base
    { from: "a@acme.com", to: "b@example.com", subject: "Hi" }
  end

  def refuses(**params)
    error = assert_raises(NaijaCloud::Email::ValidationError) do
      @client.emails.send_email(**base.merge(params))
    end
    assert_equal 0, @server.request_count, "a request was sent despite the invalid input"
    error
  end

  def test_header_injection_in_the_from_address
    INJECTIONS.each do |injection|
      error = refuses(from: "Acme <hello@acme.com>#{injection}Bcc: attacker@evil.com")
      assert_includes error.message, "from"
    end
  end

  def test_header_injection_in_a_recipient
    INJECTIONS.each do |injection|
      refuses(to: "b@example.com#{injection}Bcc: attacker@evil.com")
      refuses(to: ["ok@example.com", "b@example.com#{injection}Bcc: attacker@evil.com"])
      refuses(cc: "b@example.com#{injection}X: 1")
      refuses(bcc: "b@example.com#{injection}X: 1")
      refuses(reply_to: "b@example.com#{injection}X: 1")
    end
  end

  def test_header_injection_in_the_subject
    INJECTIONS.each do |injection|
      error = refuses(subject: "Receipt#{injection}Bcc: attacker@evil.com")
      assert_includes error.message, "subject"
    end
  end

  def test_header_injection_in_a_custom_header_value
    INJECTIONS.each do |injection|
      refuses(headers: { "X-Ref" => "1#{injection}Bcc: attacker@evil.com" })
    end
  end

  def test_a_header_name_that_is_not_a_token_is_refused
    ["X-Ref: evil", "X Ref", "X-Ref\r\nBcc", "", "X\0Ref"].each do |name|
      refuses(headers: { name => "1" })
    end
  end

  def test_header_injection_in_an_attachment_filename
    INJECTIONS.each do |injection|
      refuses(attachments: [{ filename: "in#{injection}voice.pdf", content: "bytes" }])
    end
  end

  def test_the_body_may_contain_line_breaks
    # HTML and text bodies are content, not headers. Refusing a newline there
    # would make the SDK useless for every real message.
    @server.enqueue(status: 202, body: { "id" => "m1", "status" => "queued" })

    @client.emails.send_email(**base.merge(html: "<p>one</p>\r\n<p>two</p>", text: "one\ntwo"))

    assert_equal 1, @server.request_count
  end

  def test_forbidden_custom_headers
    # Overriding any of these would sidestep the domain authorisation the From
    # address is checked against.
    %w[from to cc bcc subject dkim-signature received].each do |name|
      [name, name.upcase, name.capitalize].each do |spelling|
        error = refuses(headers: { spelling => "attacker@evil.com" })
        assert_includes error.message, "cannot be overridden"
      end
    end
  end

  def test_recipient_limit
    error = refuses(to: Array.new(51) { |i| "user#{i}@example.com" })

    assert_includes error.message, "too many recipients"
  end

  def test_the_recipient_limit_counts_to_cc_and_bcc_together
    refuses(
      to: Array.new(20) { |i| "to#{i}@example.com" },
      cc: Array.new(20) { |i| "cc#{i}@example.com" },
      bcc: Array.new(20) { |i| "bcc#{i}@example.com" },
    )
  end

  def test_fifty_recipients_are_allowed
    @server.enqueue(status: 202, body: { "id" => "m1", "status" => "queued" })

    @client.emails.send_email(**base.merge(to: Array.new(50) { |i| "user#{i}@example.com" }))

    assert_equal 1, @server.request_count
  end

  def test_header_count_limit
    headers = {}
    26.times { |i| headers["X-Ref-#{i}"] = "value" }

    error = refuses(headers: headers)

    assert_includes error.message, "too many custom headers"
  end

  def test_tag_limits
    tags = {}
    11.times { |i| tags["tag#{i}"] = "value" }
    assert_includes refuses(tags: tags).message, "too many tags"

    # The server truncates an over-long tag; the SDK refuses it, because a key
    # silently shortened stops matching the dashboard query built on it.
    refuses(tags: { "k" * 65 => "value" })
    refuses(tags: { "campaign" => "v" * 257 })
    refuses(tags: { "campaign" => 42 })
    refuses(tags: { "" => "value" })
  end

  def test_payload_size_limit
    error = refuses(html: "x" * (10 * 1024 * 1024 + 1))

    assert_includes error.message, "limit"
  end

  def test_attachment_content_must_be_bytes_not_a_handle
    refuses(attachments: [{ filename: "a.pdf", content: nil }])
    refuses(attachments: [{ filename: "a.pdf", content: 1234 }])
    refuses(attachments: [{ filename: "a.pdf", content: "" }])
    refuses(attachments: [{ filename: "", content: "bytes" }])
    refuses(attachments: [{ content: "bytes" }])
    refuses(attachments: [{ filename: "a.pdf" }])
    refuses(attachments: "not-an-array")
  end

  def test_an_unknown_attachment_key_is_refused
    error = refuses(attachments: [{ filename: "a.pdf", content: "bytes", encoding: "base64" }])

    assert_includes error.message, "encoding"
  end

  def test_addresses_must_look_like_addresses
    refuses(to: "customer")
    refuses(from: "acme")
    refuses(to: 42)
    refuses(to: ["ok@example.com", ""])
  end

  def test_type_errors_are_local_errors
    refuses(subject: 42)
    refuses(html: 42)
    refuses(headers: "X-Ref: 1")
    refuses(tags: [%w[a b]])
  end

  def test_a_non_hash_argument_is_refused
    assert_raises(NaijaCloud::Email::ValidationError) { @client.emails.send_email("just a string") }
    assert_equal 0, @server.request_count
  end
end
