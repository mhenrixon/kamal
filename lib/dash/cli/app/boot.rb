class Dash::Cli::App::Boot
  # What `docker container ls --quiet` prints, and so what dash-proxy has always been
  # handed as a target. `docker run --detach` prints the full 64-character id, so the
  # target is its first twelve characters rather than a round trip of its own.
  SHORT_CONTAINER_ID_LENGTH = 12

  attr_reader :host, :role, :version, :barrier, :sshkit, :cli
  delegate :execute, :capture_with_info, :capture_with_pretty_json, :info, :error, :upload!, to: :sshkit
  delegate :run_hook, to: :cli
  delegate :assets?, :running_proxy?, to: :role

  def initialize(host, role, sshkit, version, barrier, cli)
    @host = host
    @role = role
    @version = version
    @barrier = barrier
    @sshkit = sshkit
    @cli = cli
  end

  def run
    DASH.timings.phase("#{role} #{host}", depth: 1) do |timing|
      @timing = timing

      old_version = old_version_renamed_if_clashing

      wait_at_barrier if queuer?

      begin
        start_new_version
      rescue => e
        close_barrier if gatekeeper?
        stop_new_version
        raise
      end

      release_barrier if gatekeeper?

      if old_version
        stop_old_version(old_version)
      end
    end
  end

  private
    # Both answers come back from one round trip, which means the running version is read
    # before any rename happens. When the clashing container IS the running one, the
    # version to stop later is the name it was renamed to - the name that was read now
    # belongs to the container this boot is about to start.
    def old_version_renamed_if_clashing
      clashing_container_id, old_version = capture_boot_state

      if clashing_container_id.present?
        renamed_version = "#{version}_replaced_#{SecureRandom.hex(8)}"
        info "Renaming container #{version} to #{renamed_version} as already deployed on #{host}"
        execute *auditor.record_then("Renaming container #{version} to #{renamed_version}",
          app.rename_container(version: version, new_version: renamed_version))

        old_version = renamed_version if old_version == version
      end

      old_version
    end

    def capture_boot_state
      clashing, running = Dash::Commands::App.split_state(capture_with_info(*app.boot_state(version), raise_on_non_zero_exit: false))

      [ clashing.strip.presence, running.strip.presence ]
    end

    def start_new_version
      hostname = "#{host.to_s[0...51].chomp(".")}-#{SecureRandom.hex(6)}"

      execute *auditor.record_then("Booted app version #{version}", app.ensure_env_directory)
      upload! role.secrets_io(host), role.secrets_path, mode: "0600"

      # `docker run --detach` prints the id of the container it just started, so the
      # proxy target comes out of the run itself — asking docker for it again was a round
      # trip spent re-reading something the host had already said.
      container_id = capture_with_info(*app.run(hostname: hostname)).strip

      if running_proxy?
        endpoint = container_id[0, SHORT_CONTAINER_ID_LENGTH]
        raise Dash::Cli::BootError, "Failed to get endpoint for #{role} on #{host}, did the container boot?" if endpoint.empty?

        run_hook "pre-proxy-deploy", hosts: host.to_s, role: role.name
        info "Deploying #{role} on #{host} via dash-proxy (waiting up to #{DASH.config.deploy_timeout}s for it to become healthy)..."
        timing_healthy { execute *app.deploy(target: endpoint) }
        run_hook "post-proxy-deploy", hosts: host.to_s, role: role.name
      else
        timing_healthy { Dash::Cli::Healthcheck::Poller.wait_for_healthy(role: role, &method(:readiness_status)) }
      end
    rescue => e
      error "Failed to boot #{role} on #{host}"
      dump_diagnostics
      raise e
    end

    # A role behind the proxy lets `dash-proxy deploy` block on the host until the
    # container is healthy; a role without one now does the same, waiting in a shell loop
    # on the host that streams its progress back rather than being polled from here once
    # per attempt. The poller asks for the wait, and — only for an unchecked container it
    # has just let through its readiness delay — for a plain confirming read.
    def readiness_status(mode, seconds_left = nil)
      if mode == :confirm
        capture_with_info(*app.status(version: version))
      else
        capture_with_info *app.wait_for_ready(version: version, timeout: seconds_left),
          interaction_handler: Dash::Cli::Healthcheck::ProgressReporter.new,
          raise_on_non_zero_exit: false
      end
    end

    # Every failed boot gets the container log, and the health probe history when the
    # container declares a healthcheck — non-primary roles have no dash-proxy report to fall back on.
    def dump_diagnostics
      error capture_with_info(*app.logs(container_id: app.container_id_for_version(version)))

      health_log = capture_with_info(*app.container_health_log(version: version)).strip
      error health_log unless health_log.empty? || health_log == "null"
    rescue SSHKit::Command::Failed
      error "Could not fetch logs for #{version}"
    end

    def stop_new_version
      execute *app.stop(version: version), raise_on_non_zero_exit: false
    end

    def stop_old_version(old_version)
      run_stop_hook "pre-app-stop", old_version
      execute *app.stop(version: old_version), raise_on_non_zero_exit: false
      run_stop_hook "post-app-stop", old_version

      execute *app.clean_up_assets if assets?
      execute *app.clean_up_error_pages if DASH.config.error_pages_path
    end

    # The new version is already live by the time the old one is stopped, so a failing
    # drain hook must not fail the deploy — warn and stop the old container anyway.
    def run_stop_hook(hook, old_version)
      run_hook hook, hosts: host.to_s, role: role.name, version: old_version
    rescue Dash::Cli::HookError => e
      error "#{e.message}\nContinuing anyway: #{version} is already live for #{role} on #{host}."
    end

    def release_barrier
      if barrier.open
        info "First #{DASH.primary_role} container is healthy on #{host}, booting any other roles"
      end
    end

    def wait_at_barrier
      info "Waiting for the first healthy #{DASH.primary_role} container before booting #{role} on #{host}..."
      barrier.wait
      info "First #{DASH.primary_role} container is healthy, booting #{role} on #{host}..."
    rescue Dash::Cli::Healthcheck::Error
      info "First #{DASH.primary_role} container is unhealthy, not booting #{role} on #{host}"
      raise
    end

    def close_barrier
      if barrier.close
        info "First #{DASH.primary_role} container is unhealthy on #{host}, not booting any other roles"
      end
    end

    # The readiness wait is the part of a host's boot an operator can actually tune
    # (health check interval, app boot time), so it gets called out on the host's entry.
    def timing_healthy
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
    ensure
      @timing.detail = format("healthy after %.1fs", Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
    end

    def barrier_role?
      role == DASH.primary_role
    end

    def app
      @app ||= DASH.app(role: role, host: host)
    end

    def auditor
      @auditor = DASH.auditor(role: role)
    end

    def gatekeeper?
      barrier && barrier_role?
    end

    def queuer?
      barrier && !barrier_role?
    end
end
