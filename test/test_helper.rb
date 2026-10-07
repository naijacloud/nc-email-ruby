# frozen_string_literal: true

require "minitest/autorun"
require "socket"
require "json"
require "openssl"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "naijacloud/email"

# The literal the contract nominates for tests. It is not a key that has ever
# existed; nothing in this repo should ever hold one that has.
TEST_API_KEY = "nmail_live_test0000000000000000"

# A minimal HTTP/1.1 server on a real socket.
#
# Raw TCPServer rather than webrick: webrick left the standard library in Ruby
# 3.0, so a test suite built on it would need a gem, and "run the tests" would
# stop being a thing you can do offline on a fresh checkout. Nothing here needs
# more than a request line, some headers, and a body.
#
# Everything runs on 127.0.0.1 with an ephemeral port. The suite makes no
# outbound connection of any kind.
class MockServer
  STATUS_TEXT = {
    200 => "OK", 202 => "Accepted", 301 => "Moved Permanently", 302 => "Found",
    307 => "Temporary Redirect", 400 => "Bad Request", 401 => "Unauthorized",
    403 => "Forbidden", 404 => "Not Found", 408 => "Request Timeout",
    409 => "Conflict", 422 => "Unprocessable Entity", 429 => "Too Many Requests",
    500 => "Internal Server Error", 502 => "Bad Gateway", 503 => "Service Unavailable"
  }.freeze

  def initialize(host: "127.0.0.1")
    @host     = host
    @server   = TCPServer.new(host, 0)
    @queue    = []
    @requests = []
    @mutex    = Mutex.new
    @running  = true
    @threads  = []
    @acceptor = Thread.new { accept_loop }
  end

  def port
    @server.addr[1]
  end

  def base_url
    @host.include?(":") ? "http://[#{@host}]:#{port}" : "http://#{@host}:#{port}"
  end

  # Script one response. `body` may be a Hash (encoded as JSON) or a raw String,
  # so a test can hand back a proxy's HTML error page as easily as an API body.
  # `hang` holds the connection open without answering, which is how the
  # client-side deadline gets tested without waiting 30 seconds for the default.
  # `raw` writes the given bytes to the socket instead of a well-formed
  # response, which is how a proxy answering with garbage gets tested.
  # `trickle` sends the headers at once and then the body one byte every
  # `trickle` seconds -- a response no single socket read ever times out on.
  def enqueue(status: 200, body: "", headers: {}, hang: nil, raw: nil, trickle: nil)
    body = JSON.generate(body) unless body.is_a?(String)
    @mutex.synchronize do
      @queue << { status: status, body: body, headers: headers, hang: hang, raw: raw, trickle: trickle }
    end
    self
  end

  def requests
    @mutex.synchronize { @requests.dup }
  end

  def request_count
    @mutex.synchronize { @requests.length }
  end

  def last_request
    requests.last
  end

  def shutdown
    @running = false
    begin
      @server.close
    rescue IOError, Errno::EBADF
      nil
    end
    @acceptor.join(2)
    @threads.each { |thread| thread.join(2) }
  end

  private

  def accept_loop
    while @running
      begin
        socket = @server.accept
      rescue IOError, Errno::EBADF, Errno::EINVAL
        break
      end
      # A thread per connection so a scripted `hang` does not also stall the
      # retry that the hang is meant to provoke.
      @threads << Thread.new(socket) { |sock| handle(sock) }
    end
  end

  def handle(socket)
    request = read_request(socket)
    return if request.nil?

    @mutex.synchronize { @requests << request }
    response = @mutex.synchronize { @queue.shift } || no_script_response

    sleep(response[:hang]) if response[:hang]
    write_response(socket, response)
  rescue Errno::EPIPE, Errno::ECONNRESET, IOError
    # The client gave up first -- expected in the timeout tests.
    nil
  ensure
    begin
      socket.close
    rescue IOError
      nil
    end
  end

  def read_request(socket)
    request_line = socket.gets
    return nil if request_line.nil?

    method, path, = request_line.split(" ")
    headers = {}
    while (line = socket.gets)
      line = line.chomp
      break if line.empty?

      name, value = line.split(":", 2)
      headers[name.to_s.downcase.strip] = value.to_s.strip
    end

    length = headers["content-length"].to_i
    body   = length.positive? ? socket.read(length) : ""

    { method: method, path: path, headers: headers, body: body }
  end

  def no_script_response
    {
      status: 500,
      body: JSON.generate("statusCode" => 500, "message" => "mock server had no scripted response"),
      headers: {},
    }
  end

  def write_response(socket, response)
    return socket.write(response[:raw]) if response[:raw]

    status = response[:status]
    body   = response[:body].to_s
    lines  = ["HTTP/1.1 #{status} #{STATUS_TEXT.fetch(status, 'Status')}"]

    given = response[:headers].each_with_object({}) { |(k, v), acc| acc[k.to_s.downcase] = v }
    response[:headers].each { |name, value| lines << "#{name}: #{value}" }
    lines << "Content-Type: application/json" unless given.key?("content-type")
    lines << "Content-Length: #{body.bytesize}"
    # Close per response: the client opens a fresh connection per attempt, and a
    # kept-alive socket would leave the accept loop waiting on a peer that has
    # already moved on.
    lines << "Connection: close"

    socket.write(lines.join("\r\n") + "\r\n\r\n")
    if response[:trickle]
      body.each_char do |char|
        socket.write(char)
        socket.flush
        sleep(response[:trickle])
      end
    else
      socket.write(body)
    end
  end
end

# Base class: a server per test, a client pointed at it, and no ambient
# environment. NAIJAMAIL_API_KEY or NAIJAMAIL_BASE_URL set on the developer's
# machine would otherwise change what these tests exercise.
class NaijamailTest < Minitest::Test
  ENV_KEYS = %w[NAIJAMAIL_API_KEY NAIJAMAIL_BASE_URL].freeze

  def setup
    @saved_env = ENV_KEYS.each_with_object({}) { |key, acc| acc[key] = ENV[key] }
    ENV_KEYS.each { |key| ENV.delete(key) }
    @server = MockServer.new
  end

  def teardown
    @server.shutdown if @server
    @saved_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def build_client(**options)
    NaijaCloud::Email::Client.new(
      **{ api_key: TEST_API_KEY, base_url: @server.base_url }.merge(options),
    )
  end

  # Replaces the transport's sleep and jitter so retry timing is asserted rather
  # than waited out. Returns the array that records what would have been slept.
  # `jitter` is made deterministic (always the full ceiling) so the assertion is
  # on the backoff schedule, not on a random draw.
  def capture_sleeps(client)
    slept = []
    transport = client.instance_variable_get(:@http)
    transport.sleeper = ->(seconds) { slept << seconds }
    transport.jitter  = ->(ceiling) { ceiling }
    slept
  end

  def json_body(request)
    JSON.parse(request[:body])
  end

  # A port nothing is listening on, for the connection-refused path.
  def closed_port
    probe = TCPServer.new("127.0.0.1", 0)
    port  = probe.addr[1]
    probe.close
    port
  end

  def error_body(status, message, label = nil)
    body = { "statusCode" => status, "message" => message }
    body["error"] = label if label
    body
  end
end
