# Replaces the loadbalancer container with one booted from the current
# configuration. Shared by `dash proxy reboot` and the drift-detected reboot
# on boot - the same sequence either way, so the two paths cannot diverge.
#
# Unlike the proxy hosts' port-holder handoff this is stop -> run: the
# loadbalancer keeps its service state in the config volume, which the
# replacement container re-mounts, so every app's routes survive the gap.
class Dash::Cli::Proxy::LoadbalancerReboot
  READY_TIMEOUT = 30

  attr_reader :host, :sshkit
  delegate :execute, :capture_with_info, :info, :upload!, to: :sshkit

  def initialize(host, sshkit)
    @host = host
    @sshkit = sshkit
  end

  def run
    execute *DASH.auditor.record("Rebooted loadbalancer"), verbosity: :debug
    execute *DASH.registry.login
    ensure_network

    # After the network the bridge attaches the legacy network's containers to,
    # and before anything that could create the new container or let `docker
    # run --volume` create dash-loadbalancer-config empty: adopt the legacy
    # volume's routing table, dynamic domains and ACME cache. Carries the
    # apps-config mkdir this reboot paid a round trip for anyway
    # (zoolutions/dash#168, see Dash::Commands::Loadbalancer#legacy_rename).
    execute *DASH.loadbalancer.prepare_boot

    info "Stopping and removing #{DASH.loadbalancer.container_name} on #{host}, if running..."
    execute *DASH.loadbalancer.stop, raise_on_non_zero_exit: false
    execute *DASH.loadbalancer.remove_container

    if (lb_run = DASH.loadbalancer_config.run).secrets?
      execute *DASH.loadbalancer.ensure_proxy_directory
      upload! lb_run.secrets_io, lb_run.secrets_path, mode: "0600"
    else
      execute *DASH.loadbalancer.remove_proxy_secrets_file, raise_on_non_zero_exit: false
    end

    Dash::Cli::Proxy::LoadbalancerClaim.new(host, sshkit).claim_run_config(replace: true)
    execute *DASH.loadbalancer.run

    wait_until_ready
    verify_service if re_register_service

    # dash-proxy keeps its service state in the config volume, which the
    # replacement container re-mounts - every app's routes survive.
    services = capture_with_info(*DASH.loadbalancer.list).strip
    info "Services registered on the load balancer at #{host} after reboot:\n#{services}"
  end

  private
    # Before the old container is stopped: `docker run` against a missing
    # network would otherwise fail with the edge already down. A dedicated
    # loadbalancer host has no other path that creates the network
    # (zoolutions/dash#140).
    def ensure_network
      execute *DASH.docker.create_network
    rescue SSHKit::Command::Failed => e
      raise unless e.message.include?("already exists")
    end

    def wait_until_ready
      deadline = Time.now + READY_TIMEOUT

      begin
        capture_with_info(*DASH.loadbalancer.list, verbosity: :debug)
      rescue SSHKit::Command::Failed
        raise Dash::Cli::BootError, "the load balancer on #{host} did not become ready within #{READY_TIMEOUT} seconds" if Time.now >= deadline
        sleep 0.5
        retry
      end
    end

    # A deploy failure after this reboot must not strand a fresh LB with no
    # services: re-register this app's routes now rather than trusting the
    # deploy step that hasn't run yet, mirroring the per-host proxy reboot.
    #
    # Only this app's registration can be rebuilt from this deploy.yml - the
    # owner files of other apps sharing the LB record tokens, not deploy
    # commands - so anything else rides on the state-volume restore (which
    # --recheck-targets-on-restore re-verifies). No owner record, or a foreign
    # one, means nothing of ours to restore.
    def re_register_service
      owner = capture_with_info(*DASH.loadbalancer.read_service_owner, raise_on_non_zero_exit: false).strip
      return false unless owner == DASH.loadbalancer_config.owner_token

      info "Re-registering #{DASH.config.service} with the load balancer on #{host}..."
      execute *DASH.loadbalancer.deploy(targets: DASH.loadbalancer_config.target_hosts)
      true
    end

    # `list --json` returns {"services": {"<name>": ...}} - exact key
    # membership, same as the per-host proxy reboot's verification.
    def verify_service
      listed = JSON.parse(capture_with_info(*DASH.loadbalancer.list(json: true))).fetch("services", {}).keys

      unless listed.include?(DASH.config.service)
        raise Dash::Cli::BootError, "the load balancer on #{host} is missing service #{DASH.config.service} after reboot"
      end
    end
end
