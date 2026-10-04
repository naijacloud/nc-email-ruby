# frozen_string_literal: true

require_relative "test_helper"

class ClientTest < NaijamailTest
  def test_reads_the_api_key_from_the_environment
    ENV["NAIJAMAIL_API_KEY"] = TEST_API_KEY
    client = NaijaCloud::Email::Client.new(base_url: @server.base_url)

    @server.enqueue(status: 202, body: { "id" => "m1", "status" => "queued" })
    client.emails.send_email(from: "a@acme.com", to: "b@example.com", subject: "Hi")

    assert_equal "Bearer #{TEST_API_KEY}", @server.last_request[:headers]["authorization"]
  end

  def test_a_missing_key_names_the_environment_variable
    error = assert_raises(NaijaCloud::Email::ValidationError) do
      NaijaCloud::Email::Client.new(base_url: @server.base_url)
    end

    assert_includes error.message, "NAIJAMAIL_API_KEY"
    assert_equal 0, error.status_code
  end

  def test_a_key_of_the_wrong_shape_is_refused_locally
    bad_keys = [
      "", "   ", "sk_live_something", "nmail_live_", "nmail_live_short", "nmail_prod_abcdefghij",
      # The pre-scopes platform token. The API refuses it on the mail routes
      # outright -- it predates the Email send scope and was never granted mail
      # access -- so it fails here rather than at send time.
      "nc_pat_0123456789abcdef",
      # There is no test variant of a workspace key.
      "nc_test_0123456789abcdef"
    ]
    bad_keys.each do |key|
      assert_raises(NaijaCloud::Email::ValidationError, "expected #{key.inspect} to be refused") do
        NaijaCloud::Email::Client.new(api_key: key, base_url: @server.base_url)
      end
    end
  end

  def test_a_workspace_api_key_is_accepted
    # A key from Settings -> API keys, carrying the Email send scope.
    client = NaijaCloud::Email::Client.new(
      api_key: "nc_live_0123456789abcdefghij", base_url: @server.base_url
    )

    refute_nil client.emails
  end

  def test_a_test_key_is_accepted_by_the_constructor
    # The 403 for a test key on the send path is the server's decision, and the
    # SDK must not pre-empt it: a test key is legitimate against the retrieve
    # endpoint and in a dev environment.
    client = NaijaCloud::Email::Client.new(api_key: "nmail_test_test0000000000000000", base_url: @server.base_url)

    refute_nil client.emails
  end

  def test_a_key_with_surrounding_whitespace_is_trimmed
    ENV["NAIJAMAIL_API_KEY"] = "  #{TEST_API_KEY}\n"
    client = NaijaCloud::Email::Client.new(base_url: @server.base_url)

    @server.enqueue(status: 202, body: { "id" => "m1", "status" => "queued" })
    client.emails.send_email(from: "a@acme.com", to: "b@example.com", subject: "Hi")

    assert_equal "Bearer #{TEST_API_KEY}", @server.last_request[:headers]["authorization"]
  end

  def test_plaintext_base_url_is_refused
    error = assert_raises(NaijaCloud::Email::ValidationError) do
      NaijaCloud::Email::Client.new(api_key: TEST_API_KEY, base_url: "http://api.naijacloud.com")
    end

    assert_includes error.message, "https"
  end

  def test_plaintext_is_allowed_only_for_local_hosts
    ["http://localhost:4000", "http://127.0.0.1:4000", "http://[::1]:4000"].each do |url|
      client = NaijaCloud::Email::Client.new(api_key: TEST_API_KEY, base_url: url)
      assert_equal url, client.base_url
    end
  end

  def test_https_base_url_is_accepted
    client = NaijaCloud::Email::Client.new(api_key: TEST_API_KEY, base_url: "https://api.example.com")

    assert_equal "https://api.example.com", client.base_url
  end

  def test_base_url_comes_from_the_environment_when_not_passed
    ENV["NAIJAMAIL_BASE_URL"] = @server.base_url
    client = NaijaCloud::Email::Client.new(api_key: TEST_API_KEY)

    assert_equal @server.base_url, client.base_url
  end

  def test_default_base_url
    client = NaijaCloud::Email::Client.new(api_key: TEST_API_KEY)

    assert_equal "https://api.naijacloud.com", client.base_url
  end

  def test_a_nonsense_base_url_is_refused
    ["", "not-a-url", "ftp://example.com", "https://"].each do |url|
      assert_raises(NaijaCloud::Email::ValidationError, "expected #{url.inspect} to be refused") do
        NaijaCloud::Email::Client.new(api_key: TEST_API_KEY, base_url: url)
      end
    end
  end

  def test_timeout_and_max_retries_are_validated
    assert_raises(NaijaCloud::Email::ValidationError) { build_client(timeout: 0) }
    assert_raises(NaijaCloud::Email::ValidationError) { build_client(timeout: -1) }
    assert_raises(NaijaCloud::Email::ValidationError) { build_client(timeout: "30") }
    assert_raises(NaijaCloud::Email::ValidationError) { build_client(max_retries: -1) }
    assert_raises(NaijaCloud::Email::ValidationError) { build_client(max_retries: 1.5) }
  end

  def test_defaults_match_the_contract
    client = build_client

    assert_equal 30.0, client.timeout
    assert_equal 2, client.max_retries
  end

  def test_user_agent
    client = build_client

    assert_equal "nc-email-ruby/#{NaijaCloud::Email::VERSION} (ruby/#{RUBY_VERSION})", client.user_agent

    @server.enqueue(status: 202, body: { "id" => "m1", "status" => "queued" })
    client.emails.send_email(from: "a@acme.com", to: "b@example.com", subject: "Hi")

    assert_equal client.user_agent, @server.last_request[:headers]["user-agent"]
  end

  def test_user_agent_suffix
    client = build_client(user_agent_suffix: "acme-billing/2.1")

    assert_includes client.user_agent, "acme-billing/2.1"
    assert client.user_agent.start_with?("nc-email-ruby/")
  end

  def test_user_agent_suffix_rejects_a_line_break
    assert_raises(NaijaCloud::Email::ValidationError) do
      build_client(user_agent_suffix: "acme\r\nX-Evil: 1")
    end
  end

  def test_the_key_never_appears_in_inspect_or_to_s
    secret = "nmail_live_needle0000000000"
    client = NaijaCloud::Email::Client.new(api_key: secret, base_url: @server.base_url)
    tail   = secret.sub("nmail_live_", "")

    refute_includes client.inspect, tail
    refute_includes client.to_s, tail
    assert_includes client.inspect, "nmail_live_***"
  end

  def test_the_key_never_appears_when_instance_variables_are_dumped
    # What an error reporter, a console session or a failing assertion actually
    # prints when it is handed the client: every instance variable, inspected.
    secret = "nmail_live_needle0000000000"
    client = NaijaCloud::Email::Client.new(api_key: secret, base_url: @server.base_url)
    tail   = secret.sub("nmail_live_", "")

    dump = client.instance_variables.map { |name|
      "#{name}=#{client.instance_variable_get(name).inspect}"
    }.join(" ")

    refute_includes dump, tail
    refute_includes dump, secret
  end

  def test_the_key_never_appears_in_the_emails_resource_inspect
    secret = "nmail_live_needle0000000000"
    client = NaijaCloud::Email::Client.new(api_key: secret, base_url: @server.base_url)

    refute_includes client.emails.inspect, secret.sub("nmail_live_", "")
  end

  def test_a_client_refuses_to_be_marshalled
    client = build_client

    assert_raises(NaijaCloud::Email::Error) { Marshal.dump(client) }
  end

  def test_a_client_refuses_to_be_dumped_as_yaml
    # Psych ignores marshal_dump and walks instance variables down to the key.
    require "yaml"
    secret = "nmail_live_needle0000000000"
    client = NaijaCloud::Email::Client.new(api_key: secret, base_url: @server.base_url)

    [client, client.emails].each do |object|
      dumped = begin
        YAML.dump(object)
      rescue NaijaCloud::Email::Error
        ""
      end
      refute_includes dumped, "needle", "YAML.dump(#{object.class}) wrote the key"
    end
  end

  def test_two_clients_do_not_share_state
    # No class-level configuration anywhere: two teams' keys in one process must
    # not be able to borrow each other's credential.
    first  = NaijaCloud::Email::Client.new(api_key: "nmail_live_first000000000000", base_url: @server.base_url)
    second = NaijaCloud::Email::Client.new(api_key: "nmail_live_second00000000000", base_url: @server.base_url)

    @server.enqueue(status: 202, body: { "id" => "m1", "status" => "queued" })
    @server.enqueue(status: 202, body: { "id" => "m2", "status" => "queued" })

    first.emails.send_email(from: "a@acme.com", to: "b@example.com", subject: "one")
    second.emails.send_email(from: "a@acme.com", to: "b@example.com", subject: "two")

    sent = @server.requests.map { |request| request[:headers]["authorization"] }

    assert_equal ["Bearer nmail_live_first000000000000", "Bearer nmail_live_second00000000000"], sent
  end

  def test_a_base_url_with_a_path_prefix_is_preserved
    # Some customers front the API with a gateway on a subpath.
    client = NaijaCloud::Email::Client.new(api_key: TEST_API_KEY, base_url: "#{@server.base_url}/mail/")

    @server.enqueue(status: 202, body: { "id" => "m1", "status" => "queued" })
    client.emails.send_email(from: "a@acme.com", to: "b@example.com", subject: "Hi")

    assert_equal "/mail/v1/emails", @server.last_request[:path]
  end

  def test_redact_key
    assert_equal "nmail_live_***", NaijaCloud::Email.redact_key("nmail_live_abcdefghij")
    assert_equal "nmail_test_***", NaijaCloud::Email.redact_key("nmail_test_abcdefghij")
    # Without the second family here a workspace key falls through to the bare
    # "***", and an operator reading a dump loses the one useful signal: which
    # kind of credential this process is holding.
    assert_equal "nc_live_***", NaijaCloud::Email.redact_key("nc_live_abcdefghij")
    assert_equal "***", NaijaCloud::Email.redact_key("something-else")
    assert_equal "***", NaijaCloud::Email.redact_key(nil)
  end
end
