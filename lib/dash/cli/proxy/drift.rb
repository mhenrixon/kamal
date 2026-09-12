class Dash::Cli::Proxy::Drift
  attr_reader :host, :sshkit
  delegate :capture_with_info, to: :sshkit

  def initialize(host, sshkit)
    @host = host
    @sshkit = sshkit
  end

  # One `docker inspect` for everything a boot asks about the running proxy: whether it
  # exists, which image tag it runs, and the digest it was booted with. Captured once per
  # instance - `dash proxy boot` reads all three off it, and `dash doctor` only the first.
  def state
    @state ||= Dash::Commands::Proxy::State.parse(
      capture_with_info(*proxy.inspect_state, raise_on_non_zero_exit: false)
    )
  end

  def container_exists?
    state.exists?
  end

  # The tag the running proxy was booted from, for the minimum-version gate. Nil when
  # nothing is running - a host with no proxy has no version to be too old.
  def version
    state.version
  end

  # A proxy container has drifted when it was started with a different config
  # digest than the one the current configuration produces. Containers booted
  # by older dash versions carry no digest label and count as drifted, so
  # they converge on the first deploy after upgrading.
  def drifted?
    return @drifted if defined?(@drifted)
    @drifted = container_exists? && current_digest != expected_digest
  end

  def expected_digest
    @expected_digest ||= if proxy.proxy_run_config
      proxy.proxy_run_config.config_digest
    else
      Dash::Configuration::Proxy::Run.digest(capture_with_info(*proxy.boot_config).strip)
    end
  end

  private
    def current_digest
      state.digest.to_s
    end

    def proxy
      @proxy ||= DASH.proxy(host)
    end
end
