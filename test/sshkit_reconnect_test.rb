require "test_helper"

# A pooled connection that a NAT or cloud network silently dropped while idle
# still looks alive to SSHKit's ConnectionPool (its liveness probe is a
# non-blocking `process(0)`), so the first command on it dies with ECONNRESET,
# EPIPE or Net::SSH::Disconnect. The backend must evict that session and retry
# the block exactly once on a fresh connection.
#
# Net::SSH::Timeout means the host ignored consecutive keepalives mid-command.
# That host is unresponsive, not idle-dropped, and a retry against it can hang
# the deploy indefinitely, so it must propagate untouched.
class SshkitReconnectTest < ActiveSupport::TestCase
  FakeSession = Struct.new(:shutdowns) do
    def initialize = super(0)
    def shutdown! = self.shutdowns += 1
    def closed? = shutdowns > 0
  end

  class FakePool
    attr_reader :sessions

    def initialize
      @sessions = []
    end

    def with(_factory, *_args)
      session = FakeSession.new
      sessions << session
      yield session
    end
  end

  setup do
    @previous_pool = SSHKit::Backend::Netssh.pool
    @pool = SSHKit::Backend::Netssh.pool = FakePool.new
    @previous_output = SSHKit.config.output
    @log_io = StringIO.new
    SSHKit.config.output = Logger.new(@log_io)
    @backend = SSHKit::Backend::Netssh.new(SSHKit::Host.new("1.2.3.4"))
  end

  teardown do
    SSHKit::Backend::Netssh.pool = @previous_pool
    SSHKit.config.output = @previous_output
  end

  [ Errno::ECONNRESET, Errno::EPIPE, Net::SSH::Disconnect ].each do |error|
    test "evicts the stale session and retries once on #{error}" do
      attempts = 0

      result = @backend.send(:with_ssh) do |ssh|
        attempts += 1
        raise error, "connection lost" if attempts == 1
        [ :ok, ssh ]
      end

      assert_equal 2, attempts
      assert_equal 2, @pool.sessions.size
      assert_equal [ :ok, @pool.sessions.last ], result
      assert @pool.sessions.first.closed?, "the stale session must be shut down so the pool drops it"
      assert_not @pool.sessions.last.closed?
      assert_includes @log_io.string, "Reconnecting to 1.2.3.4"
    end
  end

  test "gives up after one reconnect" do
    attempts = 0

    assert_raises Errno::ECONNRESET do
      @backend.send(:with_ssh) do
        attempts += 1
        raise Errno::ECONNRESET
      end
    end

    assert_equal 2, attempts
    assert @pool.sessions.all?(&:closed?)
  end

  test "does not retry a host that stopped answering keepalives" do
    attempts = 0

    assert_raises Net::SSH::Timeout do
      @backend.send(:with_ssh) do
        attempts += 1
        raise Net::SSH::Timeout, "Timeout, server 1.2.3.4 not responding."
      end
    end

    assert_equal 1, attempts
    assert_equal 1, @pool.sessions.size
    assert_not_includes @log_io.string, "Reconnecting"
  end

  test "does not retry other errors" do
    attempts = 0

    assert_raises SSHKit::Command::Failed do
      @backend.send(:with_ssh) do
        attempts += 1
        raise SSHKit::Command::Failed, "exit 1"
      end
    end

    assert_equal 1, attempts
    assert_not @pool.sessions.first.closed?
  end

  test "keeps going when shutting the stale session down fails" do
    FakeSession.any_instance.stubs(:shutdown!).raises(IOError, "closed stream")
    attempts = 0

    @backend.send(:with_ssh) do
      attempts += 1
      raise Errno::EPIPE if attempts == 1
    end

    assert_equal 2, attempts
  end
end
