class Dash::Cli::Proxy::Reboot
  READY_TIMEOUT = 30

  attr_reader :host, :sshkit
  delegate :execute, :capture_with_info, :info, :upload!, to: :sshkit

  def initialize(host, sshkit)
    @host = host
    @sshkit = sshkit
  end

  def run
    execute *DASH.auditor.record("Rebooted proxy"), verbosity: :debug
    execute *DASH.registry.login

    pull_image
    replace_container
    wait_until_ready
    verify_services re_register_services
  end

  private
    def proxy
      @proxy ||= DASH.proxy(host)
    end

    def drift
      @drift ||= Dash::Cli::Proxy::Drift.new(host, sshkit)
    end

    # Pull before stopping the old container: a registry outage or rate limit
    # can then no longer strand the host with no proxy at all.
    def pull_image
      info "Pulling dash-proxy image on #{host}..."
      execute *proxy.pull
    end

    def replace_container
      execute *proxy.ensure_proxy_directory
      # Before the new container - and the new config volume `docker run
      # --volume` would otherwise create empty - exists: bring a host still on
      # pre-rename identity across. Carries the apps-config mkdir this reboot
      # paid a round trip for anyway, so the bridge costs none here either
      # (zoolutions/dash#168, see Dash::Cli::Proxy::LegacyRename).
      execute *proxy.prepare_boot
      sync_proxy_secrets

      if proxy.port_holder?
        replace_generation
      else
        stop_and_replace
      end
    end

    # Every replacement path below launches a container that reads
    # --env-file at docker run, so the secrets must be on disk before ANY
    # generation starts. This used to live inside stop_and_replace only, and
    # the port-holder paths launched their generation without it — a
    # port-holder reboot on a host without the file died with
    # "open .dash/proxy/secrets.env: no such file or directory".
    def sync_proxy_secrets
      if (run_config = proxy.proxy_run_config)&.secrets?
        upload! run_config.secrets_io, run_config.secrets_path, mode: "0600"
      else
        # A host keeps no secrets it no longer needs.
        execute *proxy.remove_proxy_secrets_file, raise_on_non_zero_exit: false
      end
    end

    # Phase 1 replacement: stop the old container, start the new one. Brief gap.
    def stop_and_replace
      info "Stopping and removing dash-proxy on #{host}, if running..."
      execute *proxy.stop(timeout: DASH.config.drain_timeout + 10), raise_on_non_zero_exit: false
      execute *proxy.remove_container

      execute *proxy.run(digest: drift.expected_digest)
    end

    # Zero-downtime replacement: overlap a new generation on the port-holder's
    # namespace, then drain the old one out.
    def replace_generation
      if holder_running?
        if generation_running?
          handoff_generation
        else
          execute *proxy.remove_container
          execute *proxy.run(digest: drift.expected_digest)
        end
      else
        migrate_to_holder
      end
    end

    def handoff_generation
      info "Handing off dash-proxy on #{host} to a new generation (zero downtime)..."
      execute *proxy.remove_stopped_container(name: proxy.next_container_name), raise_on_non_zero_exit: false
      execute *proxy.run(digest: drift.expected_digest, name: proxy.next_container_name)
      wait_until_ready(name: proxy.next_container_name)

      execute *proxy.disable_restart
      execute *proxy.drain(timeout: DASH.config.drain_timeout)
      execute *proxy.wait_for_exit
      execute *proxy.remove_stopped_container
      execute *proxy.promote_next_container
    end

    # The old proxy still owns the published ports, so the holder cannot bind
    # them until it is gone. One final replacement with a brief gap.
    def migrate_to_holder
      info "Migrating dash-proxy on #{host} to the port-holder architecture (brief gap)..."
      execute *proxy.stop(timeout: DASH.config.drain_timeout + 10), raise_on_non_zero_exit: false
      execute *proxy.remove_container

      execute *proxy.run_holder
      execute *proxy.run(digest: drift.expected_digest)
    end

    def holder_running?
      capture_with_info(*proxy.holder_container_id, raise_on_non_zero_exit: false).strip.present?
    end

    def generation_running?
      capture_with_info(*proxy.container_id(only_running: true), raise_on_non_zero_exit: false).strip.present?
    end

    def wait_until_ready(name: nil)
      deadline = Time.now + READY_TIMEOUT

      begin
        capture_with_info(*proxy.list(**{ name: name }.compact), verbosity: :debug)
      rescue SSHKit::Command::Failed
        raise Dash::Cli::BootError, "dash-proxy on #{host} did not become ready within #{READY_TIMEOUT} seconds" if Time.now >= deadline
        sleep 0.5
        retry
      end
    end

    # Re-register this app's services rather than relying solely on the
    # proxy's own state restore — a proxy that came back with missing routes
    # would otherwise 404 until the next deploy. Returns the registered
    # service names for verify_services to check.
    def re_register_services
      registered_services = []

      DASH.roles_on(host).select(&:running_proxy?).each do |role|
        app = DASH.app(role: role, host: host)

        version = capture_with_info(*app.current_running_version, raise_on_non_zero_exit: false).strip.presence
        next unless version

        endpoint = capture_with_info(*app.container_id_for_version(version, only_running: true), raise_on_non_zero_exit: false).strip.presence
        next unless endpoint

        info "Re-registering #{role.container_prefix} with dash-proxy on #{host}..."
        execute *app.deploy(target: endpoint)
        registered_services << role.container_prefix
      end

      DASH.config.accessories.select(&:running_proxy?).each do |accessory_config|
        next unless accessory_config.hosts.include?(host.to_s)

        accessory = DASH.accessory(accessory_config.name)
        target = capture_with_info(*accessory.container_id_for(container_name: accessory_config.service_name, only_running: true), raise_on_non_zero_exit: false).strip.presence
        next unless target

        info "Re-registering #{accessory_config.service_name} with dash-proxy on #{host}..."
        execute *accessory.deploy(target: target)
        registered_services << accessory_config.service_name
      end

      registered_services
    end

    # `list --json` returns {"services": {"<name>": ...}} - exact key
    # membership, where a substring match over the human table would find one
    # service's name inside another's ("app" in "other-app").
    def verify_services(registered_services)
      return if registered_services.empty?

      listed = JSON.parse(capture_with_info(*proxy.list(json: true))).fetch("services", {}).keys
      missing = registered_services - listed

      if missing.any?
        raise Dash::Cli::BootError, "dash-proxy on #{host} is missing services after reboot: #{missing.join(", ")}"
      end
    end
end
