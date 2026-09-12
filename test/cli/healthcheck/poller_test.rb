require_relative "../cli_test_case"

class CliHealthcheckPollerTest < CliTestCase
  setup do
    DASH.configure config_file: Pathname.new(File.expand_path("test/fixtures/deploy_with_readiness_sources.yml")), destination: nil, version: "999"
  end

  test "wait_for_healthy returns after the container reports healthy" do
    Dash::Cli::Healthcheck::Poller.stubs(:sleep)

    output = stdouted { wait_for_healthy(:listener, "healthy") }

    assert_match /Container is healthy!/, output
  end

  test "wait_for_healthy prints a progress beacon on each retry" do
    Dash::Cli::Healthcheck::Poller.stubs(:sleep)

    output = stdouted { wait_for_healthy(:listener, "starting", "starting", "healthy") }

    assert_match /Container not ready yet, retrying in 1s \(\d+s elapsed, \d+s left\)/, output
    assert_match /Container not ready yet, retrying in 2s \(\d+s elapsed, \d+s left\)/, output
    assert_match /Container is healthy!/, output
  end

  test "wait_for_healthy raises after the deploy timeout with no beacon spam" do
    Dash::Cli::Healthcheck::Poller.stubs(:sleep)
    DASH.config.stubs(:deploy_timeout).returns(0)

    error = assert_raises Dash::Cli::Healthcheck::Error do
      stdouted { wait_for_healthy(:listener, "starting") }
    end

    assert_match /container not ready after 0 seconds \(starting\)/, error.message
  end

  test "a role with no readiness gate warns that only the readiness delay stands in the way" do
    Dash::Cli::Healthcheck::Poller.expects(:sleep).with(7)

    output = stdouted { wait_for_healthy(:workers, "no-healthcheck:running") }

    assert_match /workers has no healthcheck/, output
    assert_match /accepting the container as ready after the 7s readiness delay alone/, output
    assert_match /Container is healthy!/, output
  end

  test "a role that opted out with healthcheck false is accepted without the warning" do
    Dash::Cli::Healthcheck::Poller.expects(:sleep).with(2)

    output = stdouted { wait_for_healthy(:silent, "no-healthcheck:running") }

    assert_no_match /has no healthcheck/, output
    assert_match /Container is healthy!/, output
  end

  test "a declared healthcheck that never reached the container fails as drift, without retrying" do
    Dash::Cli::Healthcheck::Poller.expects(:sleep).never
    calls = 0

    error = assert_raises Dash::Cli::Healthcheck::DriftError do
      stdouted do
        Dash::Cli::Healthcheck::Poller.wait_for_healthy(role: DASH.config.role(:listener)) do
          calls += 1
          "no-healthcheck:running"
        end
      end
    end

    assert_equal 1, calls
    assert_match /listener declares a healthcheck but the container reports none/, error.message
  end

  test "a hand-rolled health-cmd option that never reached the container fails as drift" do
    Dash::Cli::Healthcheck::Poller.stubs(:sleep)

    error = assert_raises Dash::Cli::Healthcheck::DriftError do
      stdouted { wait_for_healthy(:pulse, "no-healthcheck:running") }
    end

    assert_match /pulse declares a healthcheck but the container reports none/, error.message
  end

  # An exec-probed container legitimately declares no docker healthcheck — the probe runs from
  # the deploy host — so the drift check must not mistake that for flags that went missing.
  test "an exec probe reports healthy without tripping the drift check" do
    Dash::Cli::Healthcheck::Poller.stubs(:sleep)

    output = stdouted { wait_for_healthy(:prober, "healthy") }

    assert_match /Container is healthy!/, output
  end

  test "an exec probe that keeps failing times out" do
    Dash::Cli::Healthcheck::Poller.stubs(:sleep)
    DASH.config.stubs(:deploy_timeout).returns(0)

    error = assert_raises Dash::Cli::Healthcheck::Error do
      stdouted { wait_for_healthy(:prober, "exec probe exited non-zero") }
    end

    assert_match /container not ready after 0 seconds \(exec probe exited non-zero\)/, error.message
  end

  test "a healthcheck-less container that is not running reports its docker state" do
    Dash::Cli::Healthcheck::Poller.stubs(:sleep)
    DASH.config.stubs(:deploy_timeout).returns(0)

    error = assert_raises Dash::Cli::Healthcheck::Error do
      stdouted { wait_for_healthy(:workers, "no-healthcheck:exited") }
    end

    assert_match /container not ready after 0 seconds \(no-healthcheck:exited\)/, error.message
  end

  # The wait happens on the host now, so the block is asked for it once - and only an
  # unchecked container, which is accepted on its readiness delay alone, costs the one
  # further read that confirms it is still running when the delay is up.
  test "a healthchecked container is waited for once, with the time left to wait" do
    modes = []

    output = stdouted do
      Dash::Cli::Healthcheck::Poller.wait_for_healthy(role: DASH.config.role(:listener)) do |mode, seconds_left|
        modes << [ mode, seconds_left ]
        "healthy"
      end
    end

    assert_equal [ [ :wait, 30 ] ], modes
    assert_match /Container is healthy!/, output
  end

  test "an unchecked container is waited for, then confirmed after the readiness delay" do
    Dash::Cli::Healthcheck::Poller.expects(:sleep).with(7)
    modes = []

    stdouted do
      Dash::Cli::Healthcheck::Poller.wait_for_healthy(role: DASH.config.role(:workers)) do |mode, _seconds_left|
        modes << mode
        "no-healthcheck:running"
      end
    end

    assert_equal [ :wait, :confirm ], modes
  end

  # The host loop only returns early for a status this poller accepts, so a status that is
  # not acceptable means the deadline has already passed. Spending a second wait on it
  # would double what an operator waits for a boot that was never going to come up.
  test "a wait that came back unacceptable is not waited for a second time" do
    Dash::Cli::Healthcheck::Poller.expects(:sleep).never
    DASH.config.stubs(:deploy_timeout).returns(0) # the wait spent it all
    calls = 0

    assert_raises Dash::Cli::Healthcheck::Error do
      stdouted do
        Dash::Cli::Healthcheck::Poller.wait_for_healthy(role: DASH.config.role(:listener)) do
          calls += 1
          "starting"
        end
      end
    end

    assert_equal 1, calls
  end

  private
    # Yields each status in turn, then repeats the last one for every further poll.
    def wait_for_healthy(role_name, *statuses)
      Dash::Cli::Healthcheck::Poller.wait_for_healthy(role: DASH.config.role(role_name)) do
        statuses.length > 1 ? statuses.shift : statuses.first
      end
    end
end
