require_relative "cli_test_case"

class CliProxyTest < CliTestCase
  test "boot" do
    run_command("boot").tap do |output|
      assert_match "docker login", output
      assert_match "mkdir -p .dash/proxy/apps-config", output
      assert_match "echo $(cat .dash/proxy/options 2> /dev/null || echo \"--publish 80:80 --publish 443:443 --log-opt max-size=10m\") $(cat .dash/proxy/image 2> /dev/null || echo \"ghcr.io/zoolutions/dash-proxy\"):$(cat .dash/proxy/image_version 2> /dev/null || echo \"#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION}\") $(cat .dash/proxy/run_command 2> /dev/null || echo \"\") | xargs docker run --name dash-proxy --network dash --detach --restart unless-stopped --volume dash-proxy-config:/home/dash-proxy/.config/dash-proxy", output
    end
  end

  test "boot adopts the pre-rename volume on a dedicated loadbalancer host before creating the container" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)

    run_command("boot", fixture: :with_loadbalancer).tap do |output|
      copy = output.index("docker volume inspect dash-loadbalancer-config > /dev/null 2>&1 || ! docker volume inspect kamal-loadbalancer-config")
      run = output.index("docker container start load-balancer || docker run --name load-balancer")

      assert copy, "the loadbalancer host must adopt kamal-loadbalancer-config: #{output}"
      assert run, output
      assert copy < run, "the copy has to land before docker run creates the volume empty"
    end
  end

  # A dedicated loadbalancer host is not in DASH.hosts, so nothing else ever
  # creates the network there - and docker run against a missing network fails
  # after the old container was already stopped (zoolutions/dash#140).
  test "boot creates the network on a dedicated loadbalancer host before touching its container" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)

    run_command("boot", fixture: :with_loadbalancer).tap do |output|
      create = output.index("docker network create dash on lb.example.com")
      run = output.index("docker container start load-balancer || docker run --name load-balancer")

      assert create, "the loadbalancer host must get the dash network: #{output}"
      assert run, output
      assert create < run, "the network has to exist before the loadbalancer container is created"
    end
  end

  test "boot bridges the legacy network on a dedicated loadbalancer host before adopting the volume" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)

    run_command("boot", fixture: :with_loadbalancer).tap do |output|
      bridge = output.index(/docker network inspect kamal > \/dev\/null 2>&1 && docker network inspect kamal .* on lb\.example\.com/)
      copy = output.index("docker volume inspect dash-loadbalancer-config > /dev/null 2>&1 || ! docker volume inspect kamal-loadbalancer-config")

      assert bridge, "the loadbalancer host must bridge the kamal network: #{output}"
      assert copy, output
      assert bridge < copy, "the network bridge has to land before the volume copy"
    end
  end

  test "boot with drifted loadbalancer creates the network before stopping the old container" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)
    stub_loadbalancer_drift

    run_command("boot", fixture: :with_loadbalancer).tap do |output|
      create = output.index("docker network create dash on lb.example.com")
      stop = output.index("docker container stop load-balancer on lb.example.com")

      assert create, output
      assert stop, output
      assert create < stop, "a missing network must not take the edge down: create it before the old container is stopped"
    end
  end

  test "reboot with loadbalancer creates the network before stopping the old container" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)

    run_command("reboot", "-y", fixture: :with_loadbalancer).tap do |output|
      create = output.index("docker network create dash on lb.example.com")
      stop = output.index("docker container stop load-balancer on lb.example.com")

      assert create, "reboot must ensure the network on the loadbalancer host: #{output}"
      assert stop, output
      assert create < stop, "the network has to exist before the old loadbalancer container is stopped"
    end
  end

  # SSHKit prefixes the first word of every command with /usr/bin/env, and
  # `env !` is exit 127 — so no chain the gem emits may start with `!`.
  test "no command sent to a host starts with shell negation" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)

    run_command("boot", fixture: :with_loadbalancer).tap do |output|
      refute_match(/Running (\/usr\/bin\/env )?! /, output)
    end
  end

  test "boot takes the server lock so concurrent destinations serialise on the shared proxy" do
    run_command("boot").tap do |output|
      assert_match "Acquiring the server lock...", output
      assert_match "Releasing the server lock...", output
    end
  end

  test "a server lock released while its status is read is retried, not fatal" do
    # Deploy lock acquires, then the server lock is contended, then it frees up.
    Dash::Cli::Proxy.any_instance.stubs(:execute_lock_acquire)
      .returns(true)
      .then.raises(Dash::Cli::Base::LockHeldError)
      .then.returns(true)

    # The holder released between our failed mkdir and this read.
    Dash::Cli::Proxy.any_instance.stubs(:capture_lock_status)
      .raises(Dash::Cli::Base::LockMissingError)

    run_command("boot").tap do |output|
      assert_match "Acquiring the server lock...", output
      # Nothing to show, so it retried straight away instead of blowing up.
      refute_match "Server lock is held by:", output
      assert_match "Releasing the server lock...", output
    end
  end

  test "a mid-acquire failure that isn't contention rolls back the hosts already locked" do
    # Deploy lock takes, the first server-lock host takes, the second raises on a
    # pooled SSH connection that died - the failure mode from a long lock wait.
    Dash::Cli::Proxy.any_instance.stubs(:execute_lock_acquire)
      .returns(true)
      .then.returns(true)
      .then.raises(Errno::ECONNRESET)

    stub_lock_release
    expect_lock_release(host: "1.1.1.1").once

    assert_raises(Errno::ECONNRESET) { run_command("boot") }
    assert_not DASH.holding_server_lock?
  end

  test "a release that fails on one host still releases the others" do
    stub_lock_release
    expect_lock_release(host: "1.1.1.1").once.raises(Errno::ECONNRESET)
    expect_lock_release(host: "1.1.1.2").once

    assert_raises(Errno::ECONNRESET) { run_command("boot") }
  end

  test "boot with run config" do
    run_command("boot", fixture: :with_proxy_run_config).tap do |output|
      assert_match "docker login", output
      assert_match "mkdir -p .dash/proxy/apps-config", output
      assert_match_with_digest "docker container start dash-proxy || docker run --name dash-proxy --network dash --detach --restart unless-stopped --volume dash-proxy-config:/home/dash-proxy/.config/dash-proxy --label org.dash.proxy-config-digest=DIGEST --volume $PWD/.dash/proxy/apps-config:/home/dash-proxy/.apps-config --publish 80:80 --publish 443:443 --log-opt max-size=10m --expose=9090 --cpus \"1.5\" registry:4443/ghcr.io/zoolutions/dash-proxy:#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION} dash-proxy run --debug --metrics-port \"9090\" --recheck-targets-on-restore on 1.1.1.1", output
      assert_match_with_digest "docker container start dash-proxy || docker run --name dash-proxy --network dash --detach --restart unless-stopped --volume dash-proxy-config:/home/dash-proxy/.config/dash-proxy --label org.dash.proxy-config-digest=DIGEST --volume $PWD/.dash/proxy/apps-config:/home/dash-proxy/.apps-config --publish 80:80 --publish 443:443 --log-opt max-size=10m --expose=9190 ghcr.io/zoolutions/dash-proxy:#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION} dash-proxy run --metrics-port \"9190\" --recheck-targets-on-restore on 1.1.1.3", output
    end
  end

  test "boot writes acme credentials to a 0600 env file instead of the command line" do
    with_test_secrets("secrets" => "CF_API_TOKEN=zone-rewriting-token") do
      uploads = capture_uploads

      run_command("boot", fixture: :with_proxy_acme).tap do |output|
        assert_match "mkdir -p .dash/proxy on 1.1.1.1", output
        assert_match "--env-file .dash/proxy/secrets.env", output
        assert_match "--acme-email=\"admin@example.com\"", output
        assert_match "--acme-dns-provider=\"cloudflare\"", output
        assert_match "--acme-http-fallback=\"false\"", output

        assert_no_match(/zone-rewriting-token/, output)
      end

      assert_equal [ [ "CF_API_TOKEN=zone-rewriting-token\n", ".dash/proxy/secrets.env", "0600" ] ], uploads
    end
  end

  test "reboot re-uploads the acme credentials before replacing the container" do
    with_test_secrets("secrets" => "CF_API_TOKEN=zone-rewriting-token") do
      uploads = capture_uploads

      run_command("reboot", "-y", fixture: :with_proxy_acme).tap do |output|
        assert_match "--env-file .dash/proxy/secrets.env", output
        assert_no_match(/zone-rewriting-token/, output)
      end

      assert_equal [ [ "CF_API_TOKEN=zone-rewriting-token\n", ".dash/proxy/secrets.env", "0600" ] ], uploads
    end
  end

  # Regression: the port-holder replacement paths start a generation that
  # reads --env-file at docker run, but only the legacy stop_and_replace path
  # uploaded the secrets file — a port-holder reboot on a fresh host died with
  # "open .dash/proxy/secrets.env: no such file or directory".
  test "port-holder reboot uploads the acme credentials before starting the new generation" do
    with_test_secrets("secrets" => "CF_API_TOKEN=zone-rewriting-token") do
      uploads = capture_uploads

      run_command("reboot", "-y", fixture: :with_proxy_acme_port_holder).tap do |output|
        assert_match "--env-file .dash/proxy/secrets.env", output
        assert_no_match(/zone-rewriting-token/, output)
      end

      assert_equal [ [ "CF_API_TOKEN=zone-rewriting-token\n", ".dash/proxy/secrets.env", "0600" ] ], uploads
    end
  end

  test "boot delivers the cache store through the secrets env file, never printing the URL" do
    uploads = capture_uploads

    run_command("boot", fixture: :with_proxy_cache_store).tap do |output|
      assert_match "mkdir -p .dash/proxy on 1.1.1.1", output
      assert_match "--env-file .dash/proxy/secrets.env", output

      assert_no_match(/supers3cret/, output)
      assert_no_match(/--cache-store/, output)
    end

    assert_equal [ [ "CACHE_STORE=redis://:supers3cret@cache.example.com:6379/0\n", ".dash/proxy/secrets.env", "0600" ] ], uploads
  end

  # C3: a host keeps no secrets it no longer needs - when the config block
  # goes away, the next boot takes the env file with it.
  test "boot removes a stale secrets env file when the config no longer needs it" do
    run_command("boot").tap do |output|
      assert_match "rm .dash/proxy/secrets.env", output
    end
  end

  # dash-proxy list --json returns {"services": {"<name>": ...}} - exact key
  # membership, where the old substring match over the human table could match
  # a service name inside another's ("app" in "other-app").
  test "reboot fails when a re-registered service is missing from the JSON listing" do
    Object.any_instance.stubs(:sleep)
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("")
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with(:docker, :exec, "dash-proxy", "dash-proxy", :list, "--json")
      .returns({ services: { "other-app" => {} } }.to_json)
    Dash::Cli::Proxy::Reboot.any_instance.stubs(:re_register_services).returns([ "app-web" ])

    error = assert_raises(SSHKit::Runner::ExecuteError) { run_command("reboot", "-y") }
    assert_match "missing services after reboot: app-web", error.message
  end

  # The generic capture stub returns "", which JSON.parse rejects - so this
  # reboot only completes if verify_services really consulted the --json
  # listing and found the service there.
  test "reboot verifies re-registered services against the JSON listing" do
    Object.any_instance.stubs(:sleep)
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("")
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with(:docker, :exec, "dash-proxy", "dash-proxy", :list, "--json")
      .returns({ services: { "app-web" => { "target" => "abc:80" } } }.to_json)
    Dash::Cli::Proxy::Reboot.any_instance.stubs(:re_register_services).returns([ "app-web" ])

    run_command("reboot", "-y").tap do |output|
      assert_match "Rebooting dash-proxy on 1.1.1.1", output
    end
  end

  test "boot with drifted proxy reboots automatically" do
    Object.any_instance.stubs(:sleep)
    stub_proxy_drift

    run_command("boot").tap do |output|
      assert_match "dash-proxy configuration changed, rebooting on 1.1.1.1", output
      assert_match "dash-proxy configuration changed, rebooting on 1.1.1.2", output
      %w[ 1.1.1.1 1.1.1.2 ].each do |host|
        assert_match "docker pull $(cat .dash/proxy/image 2> /dev/null || echo \"ghcr.io/zoolutions/dash-proxy\"):$(cat .dash/proxy/image_version 2> /dev/null || echo \"#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION}\") on #{host}", output
        assert_match "docker container stop --time 40 dash-proxy on #{host}", output
        assert_match "docker container prune --force --filter label=org.opencontainers.image.title=dash-proxy && docker container prune --force --filter label=org.opencontainers.image.title=kamal-proxy on #{host}", output
        assert_match "--label org.dash.proxy-config-digest=#{Dash::Configuration::Proxy::Run.digest("")}", output
      end
    end
  end

  test "boot with drifted proxy and reboot_on_deploy false warns instead" do
    stub_proxy_drift

    run_command("boot", fixture: :with_proxy_reboot_disabled).tap do |output|
      assert_match "Automatic reboot is disabled (proxy: reboot_on_deploy: false) - run `dash proxy reboot` to apply the new configuration.", output
      assert_match "docker container start dash-proxy ||", output
      assert_no_match(%r{docker container stop --time \d+ dash-proxy}, output)
      assert_no_match(/rebooting on/, output)
    end
  end

  test "boot with drifted port_holder proxy hands off with zero downtime" do
    Object.any_instance.stubs(:sleep)
    stub_proxy_drift
    # Holder and old generation are running
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with(:docker, :container, :ls, "--filter", "'name=^dash-proxy-net$'", "--quiet", raise_on_non_zero_exit: false)
      .returns("holder123")
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with(:docker, :container, :ls, "--filter", "'name=^dash-proxy$'", "--quiet", raise_on_non_zero_exit: false)
      .returns("abc123")

    run_command("boot", fixture: :with_proxy_port_holder).tap do |output|
      assert_match "Handing off dash-proxy on 1.1.1.1 to a new generation (zero downtime)...", output
      assert_match_with_digest "docker run --name dash-proxy-next --network container:dash-proxy-net --detach --restart unless-stopped --volume dash-proxy-config:/home/dash-proxy/.config/dash-proxy --label org.dash.proxy-config-digest=DIGEST --volume $PWD/.dash/proxy/apps-config:/home/dash-proxy/.apps-config --log-opt max-size=10m ghcr.io/zoolutions/dash-proxy:#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION} dash-proxy run --recheck-targets-on-restore --reuse-port on 1.1.1.1", output
      assert_match "docker update --restart=no dash-proxy on 1.1.1.1", output
      assert_match "docker exec dash-proxy dash-proxy drain --drain-timeout=30s on 1.1.1.1", output
      assert_match "docker wait dash-proxy on 1.1.1.1", output
      assert_match "docker container rm dash-proxy on 1.1.1.1", output
      assert_match "docker container rename dash-proxy-next dash-proxy on 1.1.1.1", output
      assert_no_match(%r{docker container stop --time \d+ dash-proxy}, output)

      # The restart policy must be cancelled BEFORE draining - drain makes the
      # old proxy exit on its own, which an active restart policy would undo.
      assert_operator output.index("docker update --restart=no dash-proxy on 1.1.1.1"),
        :<, output.index("docker exec dash-proxy dash-proxy drain")
    end
  end

  test "boot with drifted port_holder proxy and no holder migrates with a brief gap" do
    Object.any_instance.stubs(:sleep)
    stub_proxy_drift
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with(:docker, :container, :ls, "--filter", "'name=^dash-proxy-net$'", "--quiet", raise_on_non_zero_exit: false)
      .returns("")

    run_command("boot", fixture: :with_proxy_port_holder).tap do |output|
      assert_match "Migrating dash-proxy on 1.1.1.1 to the port-holder architecture (brief gap)...", output
      assert_match "docker container stop --time 40 dash-proxy on 1.1.1.1", output
      assert_match "docker container prune --force --filter label=org.opencontainers.image.title=dash-proxy && docker container prune --force --filter label=org.opencontainers.image.title=kamal-proxy on 1.1.1.1", output
      assert_match "docker run --name dash-proxy-net --network dash --detach --restart unless-stopped --publish 80:80 --publish 443:443 --log-opt max-size=10m ghcr.io/zoolutions/dash-proxy:#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION} dash-proxy hold on 1.1.1.1", output
      assert_match_with_digest "docker run --name dash-proxy --network container:dash-proxy-net --detach --restart unless-stopped --volume dash-proxy-config:/home/dash-proxy/.config/dash-proxy --label org.dash.proxy-config-digest=DIGEST --volume $PWD/.dash/proxy/apps-config:/home/dash-proxy/.apps-config --log-opt max-size=10m ghcr.io/zoolutions/dash-proxy:#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION} dash-proxy run --recheck-targets-on-restore --reuse-port on 1.1.1.1", output
    end
  end

  test "boot with port_holder ensures the holder before starting the proxy" do
    stub_no_proxy_drift
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with(:docker, :inspect, "dash-proxy", "--format '{{.Config.Image}}'", "|", :awk, "-F:", "'{print $NF}'")
      .returns(Dash::Configuration::Proxy::Run::MINIMUM_VERSION)

    run_command("boot", fixture: :with_proxy_port_holder).tap do |output|
      assert_match "docker container start dash-proxy-net || docker run --name dash-proxy-net --network dash --detach --restart unless-stopped --publish 80:80 --publish 443:443 --log-opt max-size=10m ghcr.io/zoolutions/dash-proxy:#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION} dash-proxy hold on 1.1.1.1", output
      assert_match "docker container start dash-proxy || docker run --name dash-proxy --network container:dash-proxy-net", output
    end
  end

  test "boot with matching digest does not reboot" do
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("")
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with(:docker, :container, :ls, "--all", "--filter", "'name=^dash-proxy$'", "--quiet", raise_on_non_zero_exit: false)
      .returns("abc123")
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with(:docker, :inspect, "dash-proxy", "--format", Dash::Commands::Proxy::CONFIG_DIGEST_FORMAT, raise_on_non_zero_exit: false)
      .returns(Dash::Configuration::Proxy::Run.digest(""))

    run_command("boot").tap do |output|
      assert_match "docker container start dash-proxy ||", output
      assert_no_match(/rebooting on/, output)
      assert_no_match(%r{docker container stop --time \d+ dash-proxy}, output)
    end
  end

  test "boot with run config conflicts" do
    assert_raises Dash::ConfigurationError, "Conflicting proxy run configurations for host 1.1.1.2" do
      run_command("boot", fixture: :with_proxy_run_config_conflicts)
    end
  end

  test "boot old version" do
    Thread.report_on_exception = false
    stub_no_proxy_drift
    SSHKit::Backend::Abstract.any_instance.expects(:capture_with_info)
      .with(:docker, :inspect, "dash-proxy", "--format '{{.Config.Image}}'", "|", :awk, "-F:", "'{print $NF}'")
      .returns("v0.0.1")
      .at_least_once

    exception = assert_raises do
      run_command("boot").tap do |output|
        assert_match "docker login", output
        assert_match "echo $(cat .dash/proxy/options 2> /dev/null || echo \"--publish 80:80 --publish 443:443 --log-opt max-size=10m\") $(cat .dash/proxy/image 2> /dev/null || echo \"ghcr.io/zoolutions/dash-proxy\"):$(cat .dash/proxy/image_version 2> /dev/null || echo \"#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION}\") $(cat .dash/proxy/run_command 2> /dev/null || echo \"\") | xargs docker run --name dash-proxy --network dash --detach --restart unless-stopped --volume dash-proxy-config:/home/dash-proxy/.config/dash-proxy", output
      end
    end

    assert_includes exception.message, "dash-proxy version v0.0.1 is too old, run `dash proxy reboot` in order to update to at least #{Dash::Configuration::Proxy::Run::MINIMUM_VERSION}"
  ensure
    Thread.report_on_exception = false
  end

  test "boot correct version" do
    Thread.report_on_exception = false
    stub_no_proxy_drift
    SSHKit::Backend::Abstract.any_instance.expects(:capture_with_info)
      .with(:docker, :inspect, "dash-proxy", "--format '{{.Config.Image}}'", "|", :awk, "-F:", "'{print $NF}'")
      .returns(Dash::Configuration::Proxy::Run::MINIMUM_VERSION)
      .at_least_once

    run_command("boot").tap do |output|
      assert_match "docker login", output
      assert_match "docker container start dash-proxy || echo $(cat .dash/proxy/options 2> /dev/null || echo \"--publish 80:80 --publish 443:443 --log-opt max-size=10m\") $(cat .dash/proxy/image 2> /dev/null || echo \"ghcr.io/zoolutions/dash-proxy\"):$(cat .dash/proxy/image_version 2> /dev/null || echo \"#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION}\") $(cat .dash/proxy/run_command 2> /dev/null || echo \"\") | xargs docker run --name dash-proxy --network dash --detach --restart unless-stopped --volume dash-proxy-config:/home/dash-proxy/.config/dash-proxy", output
    end
  ensure
    Thread.report_on_exception = false
  end

  test "reboot" do
    run_command("reboot", "-y").tap do |output|
      %w[ 1.1.1.1 1.1.1.2 ].each do |host|
        assert_match "docker pull $(cat .dash/proxy/image 2> /dev/null || echo \"ghcr.io/zoolutions/dash-proxy\"):$(cat .dash/proxy/image_version 2> /dev/null || echo \"#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION}\") on #{host}", output
        assert_match "docker container stop --time 40 dash-proxy on #{host}", output
        assert_match "docker container prune --force --filter label=org.opencontainers.image.title=dash-proxy && docker container prune --force --filter label=org.opencontainers.image.title=kamal-proxy on #{host}", output
        assert_match "mkdir -p .dash/proxy/apps-config on #{host}", output
        assert_match "echo $(cat .dash/proxy/options 2> /dev/null || echo \"--publish 80:80 --publish 443:443 --log-opt max-size=10m\") $(cat .dash/proxy/image 2> /dev/null || echo \"ghcr.io/zoolutions/dash-proxy\"):$(cat .dash/proxy/image_version 2> /dev/null || echo \"#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION}\") $(cat .dash/proxy/run_command 2> /dev/null || echo \"\") | xargs docker run --name dash-proxy --network dash --detach --restart unless-stopped --volume dash-proxy-config:/home/dash-proxy/.config/dash-proxy --label org.dash.proxy-config-digest=#{Dash::Configuration::Proxy::Run.digest("")} --volume $PWD/.dash/proxy/apps-config:/home/dash-proxy/.apps-config on #{host}", output
        assert_match "docker exec dash-proxy dash-proxy list on #{host}", output
      end
    end
  end

  test "reboot --rolling" do
    run_command("reboot", "--rolling", "-y").tap do |output|
      assert_match "Running docker container prune --force --filter label=org.opencontainers.image.title=dash-proxy && docker container prune --force --filter label=org.opencontainers.image.title=kamal-proxy on 1.1.1.1", output
    end
  end

  test "start" do
    run_command("start").tap do |output|
      assert_match "docker container start dash-proxy", output
    end
  end

  test "stop" do
    run_command("stop").tap do |output|
      assert_match "docker container stop dash-proxy", output
    end
  end

  test "restart" do
    Dash::Cli::Proxy.any_instance.expects(:stop)
    Dash::Cli::Proxy.any_instance.expects(:start)

    run_command("restart")
  end

  test "details" do
    run_command("details").tap do |output|
      assert_match "docker ps --filter 'name=^dash-proxy$'", output
    end
  end

  test "logs" do
    SSHKit::Backend::Abstract.any_instance.stubs(:capture)
      .with(:docker, :logs, "dash-proxy", "--tail 100", "--timestamps", "2>&1")
      .returns("Log entry")

    SSHKit::Backend::Abstract.any_instance.stubs(:capture)
      .with(:docker, :logs, "proxy", "--tail 100", "--timestamps", "2>&1")
      .returns("Log entry")

    run_command("logs").tap do |output|
      assert_match "Proxy Host: 1.1.1.1", output
      assert_match "Log entry", output
    end
  end

  test "logs with follow" do
    SSHKit::Backend::Abstract.any_instance.stubs(:exec)
      .with("ssh -t root@1.1.1.1 -p 22 'docker logs dash-proxy --timestamps --tail 10 --follow 2>&1'")

    assert_match "docker logs dash-proxy --timestamps --tail 10 --follow", run_command("logs", "--follow")
  end

  test "remove" do
    run_command("remove").tap do |output|
      assert_match "/usr/bin/env ls .dash/apps | wc -l", output
      assert_match "docker container prune --force --filter label=org.opencontainers.image.title=dash-proxy", output
      assert_match "docker image prune --all --force --filter label=org.opencontainers.image.title=dash-proxy", output
    end
  end

  test "remove with other apps" do
    Thread.report_on_exception = false

    SSHKit::Backend::Abstract.any_instance.expects(:capture_with_info).with(:ls, ".dash/apps", "|", :wc, "-l").returns("1\n").twice

    run_command("remove").tap do |output|
      assert_match "Not removing the proxy, as other apps are installed, ignore this check with dash proxy remove --force", output
    end
  ensure
    Thread.report_on_exception = true
  end

  test "force remove with other apps" do
    Thread.report_on_exception = false

    SSHKit::Backend::Abstract.any_instance.expects(:capture_with_info).with(:ls, ".dash/apps", "|", :wc, "-l").returns("1\n").twice

    run_command("remove").tap do |output|
      assert_match "Not removing the proxy, as other apps are installed, ignore this check with dash proxy remove --force", output
    end
  ensure
    Thread.report_on_exception = true
  end

  test "remove_container" do
    run_command("remove_container").tap do |output|
      assert_match "docker container prune --force --filter label=org.opencontainers.image.title=dash-proxy", output
    end
  end

  test "remove_image" do
    run_command("remove_image").tap do |output|
      assert_match "docker image prune --all --force --filter label=org.opencontainers.image.title=dash-proxy", output
    end
  end

  test "upgrade" do
    Object.any_instance.stubs(:sleep)

    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("12345678")
    # A container already holds the version being booted, and 12345678 is running.
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with { |*args| args.join(" ").include?(Dash::Commands::App::BOOT_STATE_SEPARATOR) }
      .returns("12345678\n#{Dash::Commands::App::BOOT_STATE_SEPARATOR}\n12345678")
    stub_no_proxy_drift

    SSHKit::Backend::Abstract.any_instance.expects(:capture_with_info)
      .with(:docker, :inspect, "dash-proxy", "--format '{{.Config.Image}}'", "|", :awk, "-F:", "'{print $NF}'")
      .returns(Dash::Configuration::Proxy::Run::MINIMUM_VERSION)

    stub_readiness_wait "no-healthcheck:running", expect: true
    stub_run_capture id: "12345678" # the proxy target, printed by the run itself

    run_command("upgrade", "-y").tap do |output|
      assert_match "Upgrading proxy on 1.1.1.1,1.1.1.2,1.1.1.3,1.1.1.4...", output
      assert_match "docker login -u [REDACTED] -p [REDACTED]", output
      assert_match "docker container stop traefik ; docker container prune --force --filter label=org.opencontainers.image.title=Traefik && docker image prune --all --force --filter label=org.opencontainers.image.title=Traefik", output
      assert_match "docker container stop dash-proxy", output
      assert_match "docker container prune --force --filter label=org.opencontainers.image.title=dash-proxy", output
      assert_match "docker image prune --all --force --filter label=org.opencontainers.image.title=dash-proxy", output
      assert_match "/usr/bin/env mkdir -p .dash", output
      assert_match "docker network create dash", output
      assert_match "docker login -u [REDACTED] -p [REDACTED]", output
      assert_match "docker container start dash-proxy || echo $(cat .dash/proxy/options 2> /dev/null || echo \"--publish 80:80 --publish 443:443 --log-opt max-size=10m\") $(cat .dash/proxy/image 2> /dev/null || echo \"ghcr.io/zoolutions/dash-proxy\"):$(cat .dash/proxy/image_version 2> /dev/null || echo \"#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION}\") $(cat .dash/proxy/run_command 2> /dev/null || echo \"\") | xargs docker run --name dash-proxy --network dash --detach --restart unless-stopped --volume dash-proxy-config:/home/dash-proxy/.config/dash-proxy", output
      assert_match "/usr/bin/env mkdir -p .dash", output
      assert_match %r{docker rename app-web-latest app-web-latest_replaced_.*}, output
      assert_match "Booted app version latest\" >> .dash/app-audit.log && mkdir -p .dash/apps/app/env/roles", output
      assert_match "Uploading \"\\n\" to .dash/apps/app/env/roles/web.env", output
      assert_match %r{docker run --detach --restart unless-stopped --name app-web-latest --network dash --hostname 1.1.1.1-.* --env KAMAL_CONTAINER_NAME="app-web-latest" --env KAMAL_VERSION="latest" --env KAMAL_HOST="1.1.1.1" --env-file .dash/apps/app/env/roles/web.env --log-opt max-size="10m" --label service="app" --label role="web" --label destination dhh/app:latest}, output
      assert_match "docker exec dash-proxy dash-proxy deploy app-web --target=\"12345678:80\" --deploy-timeout=\"6s\" --drain-timeout=\"30s\" --buffer-requests --buffer-responses --log-request-header=\"Cache-Control\" --log-request-header=\"Last-Modified\" --log-request-header=\"User-Agent\"", output
      assert_match "docker container ls --all --filter 'name=^app-web-12345678$' --quiet | xargs docker stop", output
      assert_match "docker tag dhh/app:latest dhh/app:latest", output
      assert_match "/usr/bin/env mkdir -p .dash", output
      assert_match "docker ps -q -a --filter label=service=app --filter label=destination= --filter label=role=web --filter status=created --filter status=exited --filter status=dead | tail -n +6 | while read container_id; do docker rm $container_id; done", output
      assert_match "docker image prune --force --filter label=service=app", output
      assert_match "Upgraded proxy on 1.1.1.1,1.1.1.2,1.1.1.3,1.1.1.4", output
    end
  end

  test "upgrade rolling" do
    Object.any_instance.stubs(:sleep)

    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("12345678")
    stub_no_proxy_drift

    SSHKit::Backend::Abstract.any_instance.expects(:capture_with_info)
      .with(:docker, :inspect, "dash-proxy", "--format '{{.Config.Image}}'", "|", :awk, "-F:", "'{print $NF}'")
      .returns(Dash::Configuration::Proxy::Run::MINIMUM_VERSION)

    stub_readiness_wait "no-healthcheck:running", expect: true
    stub_run_capture id: "12345678" # the proxy target, printed by the run itself

    run_command("upgrade", "--rolling", "-y",).tap do |output|
      %w[1.1.1.1 1.1.1.2 1.1.1.3 1.1.1.4].each do |host|
        assert_match "Upgrading proxy on #{host}...", output
        assert_match "docker container stop traefik ; docker container prune --force --filter label=org.opencontainers.image.title=Traefik && docker image prune --all --force --filter label=org.opencontainers.image.title=Traefik on #{host}", output
        assert_match "Upgraded proxy on #{host}", output
      end
    end
  end

  test "boot_config set" do
    run_command("boot_config", "set").tap do |output|
      %w[ 1.1.1.1 1.1.1.2 ].each do |host|
        assert_match "Running /usr/bin/env mkdir -p .dash/proxy on #{host}", output
        assert_match "Running /usr/bin/env rm .dash/proxy/options on #{host}", output
        assert_match "Running /usr/bin/env rm .dash/proxy/image on #{host}", output
        assert_match "Running /usr/bin/env rm .dash/proxy/image_version on #{host}", output
        assert_match "Running /usr/bin/env rm .dash/proxy/run_command on #{host}", output
      end
    end
  end

  test "boot_config set no publish" do
    run_command("boot_config", "set", "--publish", "false").tap do |output|
      %w[ 1.1.1.1 1.1.1.2 ].each do |host|
        assert_match "Running /usr/bin/env mkdir -p .dash/proxy on #{host}", output
        assert_match "Uploading \"--log-opt max-size=10m\" to .dash/proxy/options on #{host}", output
        assert_match "Running /usr/bin/env rm .dash/proxy/image on #{host}", output
        assert_match "Running /usr/bin/env rm .dash/proxy/image_version on #{host}", output
        assert_match "Running /usr/bin/env rm .dash/proxy/run_command on #{host}", output
      end
    end
  end

  test "boot_config set custom max_size" do
    run_command("boot_config", "set", "--log-max-size", "100m").tap do |output|
      %w[ 1.1.1.1 1.1.1.2 ].each do |host|
        assert_match "Running /usr/bin/env mkdir -p .dash/proxy on #{host}", output
        assert_match "Uploading \"--publish 80:80 --publish 443:443 --log-opt max-size=100m\" to .dash/proxy/options on #{host}", output
        assert_match "Running /usr/bin/env rm .dash/proxy/image on #{host}", output
        assert_match "Running /usr/bin/env rm .dash/proxy/image_version on #{host}", output
        assert_match "Running /usr/bin/env rm .dash/proxy/run_command on #{host}", output
      end
    end
  end

  test "boot_config set no log max size" do
    run_command("boot_config", "set", "--log-max-size=").tap do |output|
      %w[ 1.1.1.1 1.1.1.2 ].each do |host|
        assert_match "Running /usr/bin/env mkdir -p .dash/proxy on #{host}", output
        assert_match "Uploading \"--publish 80:80 --publish 443:443\" to .dash/proxy/options on #{host}", output
        assert_match "Running /usr/bin/env rm .dash/proxy/image on #{host}", output
        assert_match "Running /usr/bin/env rm .dash/proxy/image_version on #{host}", output
        assert_match "Running /usr/bin/env rm .dash/proxy/run_command on #{host}", output
      end
    end
  end

  test "boot_config set custom ports" do
    run_command("boot_config", "set", "--http-port", "8080", "--https-port", "8443").tap do |output|
      %w[ 1.1.1.1 1.1.1.2 ].each do |host|
        assert_match "Running /usr/bin/env mkdir -p .dash/proxy on #{host}", output
        assert_match "Uploading \"--publish 8080:80 --publish 8443:443 --log-opt max-size=10m\" to .dash/proxy/options on #{host}", output
      end
    end
  end

  test "boot_config set bind IP" do
    run_command("boot_config", "set", "--publish-host-ip", "127.0.0.1").tap do |output|
      %w[ 1.1.1.1 1.1.1.2 ].each do |host|
        assert_match "Running /usr/bin/env mkdir -p .dash/proxy on #{host}", output
        assert_match "Uploading \"--publish 127.0.0.1:80:80 --publish 127.0.0.1:443:443 --log-opt max-size=10m\" to .dash/proxy/options on #{host}", output
      end
    end
  end

  test "boot_config set multiple bind IPs" do
    run_command("boot_config", "set", "--publish-host-ip", "127.0.0.1", "--publish-host-ip", "::1").tap do |output|
      %w[ 1.1.1.1 1.1.1.2 ].each do |host|
        assert_match "Running /usr/bin/env mkdir -p .dash/proxy on #{host}", output
        assert_match "Uploading \"--publish 127.0.0.1:80:80 --publish 127.0.0.1:443:443 --publish [::1]:80:80 --publish [::1]:443:443 --log-opt max-size=10m\" to .dash/proxy/options on #{host}", output
      end
    end
  end

  test "boot_config set invalid bind IPs" do
    exception = assert_raises do
      run_command("boot_config", "set", "--publish-host-ip", "1.2.3.invalidIP", "--publish-host-ip", "::1")
    end

    assert_includes exception.message, "Invalid publish IP address: 1.2.3.invalidIP"
  end

  test "boot_config set docker options" do
    run_command("boot_config", "set", "--docker_options", "label=foo=bar", "add_host=thishost:thathost").tap do |output|
      %w[ 1.1.1.1 1.1.1.2 ].each do |host|
        assert_match "Running /usr/bin/env mkdir -p .dash/proxy on #{host}", output
        assert_match "Uploading \"--publish 80:80 --publish 443:443 --log-opt max-size=10m --label=foo=bar --add_host=thishost:thathost\" to .dash/proxy/options on #{host}", output
        assert_match "Running /usr/bin/env rm .dash/proxy/image on #{host}", output
        assert_match "Running /usr/bin/env rm .dash/proxy/image_version on #{host}", output
        assert_match "Running /usr/bin/env rm .dash/proxy/run_command on #{host}", output
      end
    end
  end

  test "boot_config set registry" do
    run_command("boot_config", "set", "--registry", "myreg").tap do |output|
      %w[ 1.1.1.1 1.1.1.2 ].each do |host|
        assert_match "Running /usr/bin/env mkdir -p .dash/proxy on #{host}", output
        assert_match "Running /usr/bin/env rm .dash/proxy/options on #{host}", output
        assert_match "Uploading \"myreg/ghcr.io/zoolutions/dash-proxy\" to .dash/proxy/image on #{host}", output
        assert_match "Running /usr/bin/env rm .dash/proxy/image_version on #{host}", output
        assert_match "Running /usr/bin/env rm .dash/proxy/run_command on #{host}", output
      end
    end
  end

  test "boot_config set repository" do
    run_command("boot_config", "set", "--repository", "myrepo").tap do |output|
      %w[ 1.1.1.1 1.1.1.2 ].each do |host|
        assert_match "Running /usr/bin/env mkdir -p .dash/proxy on #{host}", output
        assert_match "Running /usr/bin/env rm .dash/proxy/options on #{host}", output
        assert_match "Uploading \"myrepo/dash-proxy\" to .dash/proxy/image on #{host}", output
        assert_match "Running /usr/bin/env rm .dash/proxy/image_version on #{host}", output
        assert_match "Running /usr/bin/env rm .dash/proxy/run_command on #{host}", output
      end
    end
  end

  test "boot_config set image_version" do
    run_command("boot_config", "set", "--image_version", "0.9.9").tap do |output|
      %w[ 1.1.1.1 1.1.1.2 ].each do |host|
        assert_match "Running /usr/bin/env mkdir -p .dash/proxy on #{host}", output
        assert_match "Running /usr/bin/env rm .dash/proxy/options on #{host}", output
        assert_match "Running /usr/bin/env rm .dash/proxy/image on #{host}", output
        assert_match "Uploading \"0.9.9\" to .dash/proxy/image_version on #{host}", output
        assert_match "Running /usr/bin/env rm .dash/proxy/run_command on #{host}", output
      end
    end
  end

  test "boot_config set run_command" do
    run_command("boot_config", "set", "--metrics_port", "9000", "--debug", "true").tap do |output|
      %w[ 1.1.1.1 1.1.1.2 ].each do |host|
        assert_match "Running /usr/bin/env mkdir -p .dash/proxy on #{host}", output
        assert_match "Uploading \"--publish 80:80 --publish 443:443 --log-opt max-size=10m --expose=9000\" to .dash/proxy/options on #{host}", output
        assert_match "Running /usr/bin/env rm .dash/proxy/image on #{host}", output
        assert_match "Running /usr/bin/env rm .dash/proxy/image_version on #{host}", output
        assert_match "Uploading \"dash-proxy run --debug --metrics-port \\\"9000\\\"\" to .dash/proxy/run_command on #{host}", output
      end
    end
  end

  test "boot_config set all" do
    run_command("boot_config", "set", "--docker_options", "label=foo=bar", "--registry", "myreg", "--repository", "myrepo", "--image_version", "0.9.9", "--metrics_port", "9000", "--debug", "true").tap do |output|
      %w[ 1.1.1.1 1.1.1.2 ].each do |host|
        assert_match "Uploading \"--publish 80:80 --publish 443:443 --log-opt max-size=10m --expose=9000 --label=foo=bar\" to .dash/proxy/options on #{host}", output
        assert_match "Uploading \"myreg/myrepo/dash-proxy\" to .dash/proxy/image on #{host}", output
        assert_match "Uploading \"0.9.9\" to .dash/proxy/image_version on #{host}", output
        assert_match "Uploading \"dash-proxy run --debug --metrics-port \\\"9000\\\"\" to .dash/proxy/run_command on #{host}", output
      end
    end
  end

  test "boot_config get" do
    SSHKit::Backend::Abstract.any_instance.expects(:capture_with_info)
      .with(:echo, "$(cat .dash/proxy/options 2> /dev/null || echo \"--publish 80:80 --publish 443:443 --log-opt max-size=10m\") $(cat .dash/proxy/image 2> /dev/null || echo \"ghcr.io/zoolutions/dash-proxy\"):$(cat .dash/proxy/image_version 2> /dev/null || echo \"#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION}\") $(cat .dash/proxy/run_command 2> /dev/null || echo \"\")")
      .returns("--publish 80:80 --publish 8443:443 --label=foo=bar ghcr.io/zoolutions/dash-proxy:v1.0.0")
      .twice

    run_command("boot_config", "get").tap do |output|
      assert_match "Host 1.1.1.1: --publish 80:80 --publish 8443:443 --label=foo=bar ghcr.io/zoolutions/dash-proxy:v1.0.0", output
      assert_match "Host 1.1.1.2: --publish 80:80 --publish 8443:443 --label=foo=bar ghcr.io/zoolutions/dash-proxy:v1.0.0", output
    end
  end

  test "boot_config reset" do
    run_command("boot_config", "reset").tap do |output|
      %w[ 1.1.1.1 1.1.1.2 ].each do |host|
        assert_match "rm .dash/proxy/options on #{host}", output
      end
    end
  end

  # Domains tests
  test "domains refresh" do
    SSHKit::Backend::Abstract.any_instance.expects(:capture_with_info)
      .with(:docker, :exec, "dash-proxy", "dash-proxy", "domains", "refresh")
      .returns("Refresh queued")
      .at_least_once

    run_command("domains", "refresh").tap do |output|
      # Runs against every proxy host, not just the primary
      assert_match "Proxy Host: 1.1.1.1", output
      assert_match "Proxy Host: 1.1.1.2", output
      assert_match "Refresh queued", output
    end
  end

  test "domains stats" do
    SSHKit::Backend::Abstract.any_instance.expects(:capture_with_info)
      .with(:docker, :exec, "dash-proxy", "dash-proxy", "domains", "stats")
      .returns("certs: 3 pending: 1")
      .at_least_once

    run_command("domains", "stats").tap do |output|
      assert_match "certs: 3 pending: 1", output
    end
  end

  # A held domain normally frees itself once DNS points at the proxy; retry is
  # for the operator who already knows the cause is fixed.
  test "domains retry with a host" do
    SSHKit::Backend::Abstract.any_instance.expects(:capture_with_info)
      .with(:docker, :exec, "dash-proxy", "dash-proxy", "domains", "retry", "app.example.com")
      .returns("Cleared 1 issuance hold")
      .at_least_once

    run_command("domains", "retry", "app.example.com").tap do |output|
      assert_match "Cleared 1 issuance hold", output
    end
  end

  test "domains retry --all" do
    SSHKit::Backend::Abstract.any_instance.expects(:capture_with_info)
      .with(:docker, :exec, "dash-proxy", "dash-proxy", "domains", "retry", "--all")
      .returns("Cleared 3 issuance holds")
      .at_least_once

    run_command("domains", "retry", "--all").tap do |output|
      assert_match "Cleared 3 issuance holds", output
    end
  end

  test "domains rejects an unknown subcommand" do
    run_command("domains", "bogus").tap do |output|
      assert_match "Unknown domains subcommand: bogus", output
      assert_match "retry", output
    end
  end

  # Cache admin surfaces on the layer that owns the cache: the loadbalancer
  # when load balancing (cache policy is edge-only), else the proxy hosts.
  test "cache stats" do
    SSHKit::Backend::Abstract.any_instance.expects(:capture_with_info)
      .with(:docker, :exec, "dash-proxy", "dash-proxy", :cache, :stats)
      .returns("Response cache (per node): 12 entries").twice

    run_command("cache", "stats").tap do |output|
      assert_match "12 entries", output
    end
  end

  test "cache stats passes count and json through" do
    SSHKit::Backend::Abstract.any_instance.expects(:capture_with_info)
      .with(:docker, :exec, "dash-proxy", "dash-proxy", :cache, :stats, "--count", "--json")
      .returns("{}").twice

    run_command("cache", "stats", "--count", "--json").tap do |output|
      assert_match "{}", output
    end
  end

  test "cache stats with loadbalancer asks the loadbalancer" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)

    SSHKit::Backend::Abstract.any_instance.expects(:capture_with_info)
      .with(:docker, :exec, "load-balancer", "dash-proxy", :cache, :stats)
      .returns("Response cache (shared): 40 entries")

    run_command("cache", "stats", fixture: :with_loadbalancer).tap do |output|
      assert_match "Loadbalancer Host: lb.example.com", output
      assert_match "40 entries", output
    end
  end

  # Without a loadbalancer, each proxied role registered its own service, so
  # purge walks them per host.
  test "cache purge purges each proxied role service" do
    SSHKit::Backend::Abstract.any_instance.expects(:capture_with_info)
      .with(:docker, :exec, "dash-proxy", "dash-proxy", :cache, :purge, "app-web")
      .returns("Purged 3 cached responses").twice

    run_command("cache", "purge").tap do |output|
      assert_match "Purged 3 cached responses", output
    end
  end

  test "cache purge passes the path prefix through" do
    SSHKit::Backend::Abstract.any_instance.expects(:capture_with_info)
      .with(:docker, :exec, "dash-proxy", "dash-proxy", :cache, :purge, "app-web", "--path-prefix", "\"/assets\"")
      .returns("Purged 1 cached response").twice

    run_command("cache", "purge", "--path-prefix", "/assets").tap do |output|
      assert_match "Purged 1 cached response", output
    end
  end

  test "cache purge with loadbalancer purges the bare service on the loadbalancer" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)

    SSHKit::Backend::Abstract.any_instance.expects(:capture_with_info)
      .with(:docker, :exec, "load-balancer", "dash-proxy", :cache, :purge, "app")
      .returns("Purged 7 cached responses")

    run_command("cache", "purge", fixture: :with_loadbalancer).tap do |output|
      assert_match "Loadbalancer Host: lb.example.com", output
      assert_match "Purged 7 cached responses", output
    end
  end

  test "cache with an unknown subcommand" do
    run_command("cache", "flush").tap do |output|
      assert_match "Unknown cache subcommand: flush. Available: stats, purge", output
    end
  end

  test "domains list with loadbalancer" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)

    SSHKit::Backend::Abstract.any_instance.expects(:capture_with_info)
      .with(:docker, :exec, "load-balancer", "dash-proxy", "domains", "list")
      .returns("customer1.example.com")

    run_command("domains", "list", fixture: :with_loadbalancer).tap do |output|
      assert_match "Loadbalancer Host: lb.example.com", output
      assert_match "customer1.example.com", output
    end
  end

  test "domains refresh with loadbalancer on proxy host uses proxy container name" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)

    SSHKit::Backend::Abstract.any_instance.expects(:capture_with_info)
      .with(:docker, :exec, "dash-proxy", "dash-proxy", "domains", "refresh")
      .returns("Refresh queued")

    run_command("domains", "refresh", fixture: :with_loadbalancer_on_proxy_host).tap do |output|
      assert_match "Loadbalancer Host: 1.1.1.1", output
      assert_match "Refresh queued", output
    end
  end

  test "domains with unknown subcommand" do
    run_command("domains", "bogus").tap do |output|
      assert_match "Unknown domains subcommand: bogus. Available: refresh, list, stats", output
    end
  end

  # Loadbalancer tests
  test "boot with loadbalancer" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)

    run_command("boot", fixture: :with_loadbalancer).tap do |output|
      assert_match "docker login", output
      assert_match "mkdir -p .dash/proxy/apps-config", output
      # Check loadbalancer is started
      assert_match "Starting loadbalancer on lb.example.com", output
      assert_match "docker container start load-balancer || docker run --name load-balancer", output
      assert_match "ghcr.io/zoolutions/dash-proxy:#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION} dash-proxy run", output
    end
  end

  # The load balancer terminates TLS, so it must be able to issue certificates:
  # the acme credentials env file has to reach its host too, not only the
  # per-app proxy hosts.
  test "boot with loadbalancer uploads the acme credentials to the loadbalancer host" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)

    with_test_secrets("secrets" => "CF_API_TOKEN=zone-rewriting-token") do
      uploads = capture_uploads

      run_command("boot", fixture: :with_loadbalancer_acme).tap do |output|
        assert_match "mkdir -p .dash/proxy on lb.example.com", output
        assert_match "--env-file .dash/proxy/secrets.env", output
        assert_match "--acme-email=\"admin@example.com\"", output

        assert_no_match(/zone-rewriting-token/, output)
      end

      assert_includes uploads, [ "CF_API_TOKEN=zone-rewriting-token\n", ".dash/proxy/secrets.env", "0600" ]
    end
  end

  test "reboot with loadbalancer re-uploads the acme credentials before replacing the container" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)

    with_test_secrets("secrets" => "CF_API_TOKEN=zone-rewriting-token") do
      uploads = capture_uploads

      run_command("reboot", "-y", fixture: :with_loadbalancer_acme).tap do |output|
        assert_match "mkdir -p .dash/proxy on lb.example.com", output
        assert_no_match(/zone-rewriting-token/, output)
      end

      assert_includes uploads, [ "CF_API_TOKEN=zone-rewriting-token\n", ".dash/proxy/secrets.env", "0600" ]
    end
  end

  # E3: the auto-activated loadbalancer gets the same drift detection the
  # proxy hosts have - a config change reboots it on the next deploy instead
  # of leaving the old container serving indefinitely.
  test "boot with drifted loadbalancer reboots it automatically" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)
    stub_loadbalancer_drift

    run_command("boot", fixture: :with_loadbalancer).tap do |output|
      assert_match "Loadbalancer configuration changed, rebooting on lb.example.com", output
      assert_match "docker container stop load-balancer on lb.example.com", output
      assert_match "docker container prune --force --filter label=org.opencontainers.image.title=dash-loadbalancer && docker container prune --force --filter label=org.opencontainers.image.title=kamal-loadbalancer on lb.example.com", output
      assert_match "docker run --name load-balancer", output
    end
  end

  test "boot with drifted loadbalancer and reboot_on_deploy false warns instead" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)
    Dash::Configuration::Proxy.any_instance.stubs(:reboot_on_deploy?).returns(false)
    stub_loadbalancer_drift

    run_command("boot", fixture: :with_loadbalancer).tap do |output|
      assert_match "The loadbalancer on lb.example.com is running with a configuration that no longer matches the deploy config", output
      assert_no_match(/docker container prune --force --filter label=org.opencontainers.image.title=dash-loadbalancer/, output)
      # The old container keeps serving.
      assert_match "docker container start load-balancer", output
    end
  end

  test "reboot with loadbalancer" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)

    run_command("reboot", "-y", fixture: :with_loadbalancer).tap do |output|
      # Check proxy is rebooted on web hosts
      assert_match "docker container stop --time 40 dash-proxy on 1.1.1.1", output
      assert_match "docker container stop --time 40 dash-proxy on 1.1.1.2", output

      # Check loadbalancer is rebooted
      assert_match "Stopping and removing load-balancer on lb.example.com, if running", output
      assert_match "docker container stop load-balancer", output
      assert_match "docker container prune --force --filter label=org.opencontainers.image.title=dash-loadbalancer", output
      assert_match "docker run --name load-balancer", output
      assert_match "ghcr.io/zoolutions/dash-proxy:#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION} dash-proxy run", output
    end
  end

  test "details with loadbalancer" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)

    run_command("details", fixture: :with_loadbalancer).tap do |output|
      assert_match "docker ps --filter 'name=^dash-proxy$'", output
      assert_match "docker ps --filter 'name=^load-balancer$'", output
    end
  end

  test "loadbalancer info" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)

    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with(:docker, :ps, "--filter", "'name=^load-balancer$'")
      .returns("CONTAINER ID   IMAGE   STATUS")

    run_command("loadbalancer", "info", fixture: :with_loadbalancer).tap do |output|
      assert_match "Loadbalancer status on lb.example.com", output
    end
  end

  test "loadbalancer start" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)

    run_command("loadbalancer", "start", fixture: :with_loadbalancer).tap do |output|
      assert_match "docker login", output
      assert_match "docker container start load-balancer || docker run --name load-balancer", output
    end
  end

  test "loadbalancer stop" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)

    run_command("loadbalancer", "stop", fixture: :with_loadbalancer).tap do |output|
      assert_match "docker container stop load-balancer", output
    end
  end

  test "loadbalancer logs" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)

    SSHKit::Backend::Abstract.any_instance.stubs(:capture)
      .with(:docker, :logs, "load-balancer", "--timestamps", "2>&1")
      .returns("Loadbalancer log entry")

    run_command("loadbalancer", "logs", fixture: :with_loadbalancer).tap do |output|
      assert_match "Loadbalancer Host: lb.example.com", output
      assert_match "Loadbalancer log entry", output
    end
  end

  test "loadbalancer deploy" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)

    run_command("loadbalancer", "deploy", fixture: :with_loadbalancer).tap do |output|
      assert_match "Deploying to loadbalancer on lb.example.com with targets: 1.1.1.1, 1.1.1.2", output
      assert_match "docker exec load-balancer dash-proxy deploy app --target=\"1.1.1.1:80,1.1.1.2:80\" --host=\"app.example.com\" --tls --deploy-timeout=\"6s\" --drain-timeout=\"30s\" --buffer-requests --buffer-responses --log-request-header=\"Cache-Control\" --log-request-header=\"Last-Modified\" --log-request-header=\"User-Agent\"", output
    end
  end

  test "loadbalancer info when not configured" do
    run_command("loadbalancer", "info").tap do |output|
      assert_match "Load balancing is not configured", output
    end
  end

  test "remove_container with loadbalancer" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)

    run_command("remove_container", fixture: :with_loadbalancer).tap do |output|
      assert_match "docker container prune --force --filter label=org.opencontainers.image.title=dash-proxy", output
      assert_match "docker container prune --force --filter label=org.opencontainers.image.title=dash-loadbalancer", output
    end
  end

  test "remove_image with loadbalancer" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)

    # The load balancer runs the dash-proxy image, so it is pruned by the
    # dash-proxy title label - on its own host as well as on a shared one.
    run_command("remove_image", fixture: :with_loadbalancer).tap do |output|
      assert_match "docker image prune --all --force --filter label=org.opencontainers.image.title=dash-proxy && docker image prune --all --force --filter label=org.opencontainers.image.title=kamal-proxy on 1.1.1.1", output
      assert_match "docker image prune --all --force --filter label=org.opencontainers.image.title=dash-proxy && docker image prune --all --force --filter label=org.opencontainers.image.title=kamal-proxy on lb.example.com", output
    end
  end

  # Shared host tests - loadbalancer on same server as proxy
  test "boot with loadbalancer on proxy host" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)

    run_command("boot", fixture: :with_loadbalancer_on_proxy_host).tap do |output|
      # Proxy should only boot on 1.1.1.2 (not 1.1.1.1 which is loadbalancer)
      assert_match "docker container start dash-proxy || echo", output
      # Loadbalancer boots on 1.1.1.1 with dash-proxy name and proxy volume mounts
      assert_match "Starting loadbalancer on 1.1.1.1", output
      assert_match "docker container start dash-proxy || docker run --name dash-proxy", output
      # Check that loadbalancer uses proxy-compatible config
      assert_match "dash-proxy-config:/home/dash-proxy/.config/dash-proxy", output
      assert_match ".dash/proxy/apps-config:/home/dash-proxy/.apps-config", output
    end
  end

  test "reboot with loadbalancer on proxy host" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)

    run_command("reboot", "-y", fixture: :with_loadbalancer_on_proxy_host).tap do |output|
      # Proxy reboots only on 1.1.1.2
      assert_match "docker container stop --time 40 dash-proxy on 1.1.1.2", output
      # Loadbalancer reboots on 1.1.1.1 using dash-proxy container name
      assert_match "Stopping and removing dash-proxy on 1.1.1.1", output
    end
  end

  test "loadbalancer on proxy host uses proxy container name" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)

    run_command("loadbalancer", "info", fixture: :with_loadbalancer_on_proxy_host).tap do |output|
      # When on proxy host, loadbalancer uses dash-proxy container name
      assert_match "docker ps --filter 'name=^dash-proxy$'", output
    end
  end

  # --- Shared loadbalancer tier: two dash apps, one load balancer host -------

  test "loadbalancer deploy claims the service name for this app" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)
    stub_loadbalancer_registry

    run_command("loadbalancer", "deploy", fixture: :with_loadbalancer).tap do |output|
      assert_match "mkdir -p .dash/loadbalancer/services", output
      assert_match "docker exec load-balancer dash-proxy deploy app", output
    end
  end

  test "loadbalancer deploy is a no-op claim when this app already owns the service" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)
    stub_loadbalancer_registry(service_owner: loadbalancer_owner_token(:with_loadbalancer))

    run_command("loadbalancer", "deploy", fixture: :with_loadbalancer).tap do |output|
      assert_match "docker exec load-balancer dash-proxy deploy app", output
      assert_no_match(/is already registered on the load balancer/, output)
    end
  end

  test "loadbalancer deploy errors when another app owns the service name" do
    Thread.report_on_exception = false
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)
    stub_loadbalancer_registry(service_owner: "app other/app")

    error = assert_raises(SSHKit::Runner::ExecuteError) do
      run_command("loadbalancer", "deploy", fixture: :with_loadbalancer)
    end

    assert_match "Service 'app' is already registered on the load balancer at lb.example.com by other/app", error.message
    assert_match "rename this app's service", error.message
  ensure
    Thread.report_on_exception = true
  end

  test "boot records this app's run configuration for the shared load balancer" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)
    stub_loadbalancer_registry

    run_command("boot", fixture: :with_loadbalancer).tap do |output|
      assert_match "Starting loadbalancer on lb.example.com", output
    end
  end

  test "boot errors when another app booted the load balancer with a different proxy.run" do
    Thread.report_on_exception = false
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)
    stub_loadbalancer_registry(run_config: "other-app other/app some-other-digest")

    error = assert_raises(SSHKit::Runner::ExecuteError) do
      run_command("boot", fixture: :with_loadbalancer)
    end

    assert_match "The load balancer on lb.example.com was booted by other/app with a different proxy/run configuration", error.message
  ensure
    Thread.report_on_exception = true
  end

  # Two apps agreeing on proxy/run is precisely the supported shared topology.
  test "boot allows another app that booted the load balancer with the same proxy.run" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)
    digest = loadbalancer_config(:with_loadbalancer).run_config_digest
    stub_loadbalancer_registry(run_config: "other-app other/app #{digest}")

    run_command("boot", fixture: :with_loadbalancer).tap do |output|
      assert_match "Starting loadbalancer on lb.example.com", output
    end
  end

  # Same app, changed config: mirror the per-host proxy's stale-config message
  # rather than erroring - `dash proxy reboot` is the documented fix.
  test "boot warns when this app's own load balancer run config is stale" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)
    stub_loadbalancer_registry(run_config: "#{loadbalancer_owner_token(:with_loadbalancer)} stale-digest")

    run_command("boot", fixture: :with_loadbalancer).tap do |output|
      assert_match "load balancer on lb.example.com is running with a configuration that no longer matches", output
      assert_match "dash proxy reboot", output
    end
  end

  # dash-proxy persists its service state in the dash-loadbalancer-config
  # named volume, so replacing the container keeps every app's routes.
  test "reboot preserves other apps services registered on the shared load balancer" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)
    stub_loadbalancer_registry
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with(:docker, :exec, "load-balancer", "dash-proxy", :list)
      .returns("app\nother-app")

    run_command("reboot", "-y", fixture: :with_loadbalancer).tap do |output|
      # The container is replaced, but the state volume is re-mounted, never
      # removed - at the path dash-proxy actually reads its state from.
      assert_match "docker container prune --force --filter label=org.opencontainers.image.title=dash-loadbalancer", output
      assert_match "--volume dash-loadbalancer-config:/home/dash-proxy/.config/dash-proxy", output
      assert_no_match(/docker volume rm/, output)

      # And the persisted service list is reported back after the restart.
      assert_match "Services registered on the load balancer at lb.example.com after reboot", output
      assert_match "other-app", output
    end
  end

  # The LB reboot path must not rely solely on the deploy step that follows
  # it: if that step fails, a freshly rebooted LB would be stranded with no
  # services and the site down. Re-register this app's routes immediately,
  # mirroring the per-host proxy reboot, and verify via the JSON listing.
  test "reboot re-registers this apps service on the load balancer and verifies it" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)
    stub_loadbalancer_registry(service_owner: loadbalancer_owner_token(:with_loadbalancer))
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with(:docker, :exec, "load-balancer", "dash-proxy", :list, "--json")
      .returns({ services: { "app" => { "target" => "1.1.1.1:80" } } }.to_json)

    run_command("reboot", "-y", fixture: :with_loadbalancer).tap do |output|
      assert_match "Re-registering app with the load balancer on lb.example.com", output
      assert_match "docker exec load-balancer dash-proxy deploy app --target=\"1.1.1.1:80,1.1.1.2:80\"", output
    end
  end

  test "reboot fails when the load balancer is missing this apps service after re-registration" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)
    stub_loadbalancer_registry(service_owner: loadbalancer_owner_token(:with_loadbalancer))
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with(:docker, :exec, "load-balancer", "dash-proxy", :list, "--json")
      .returns({ services: { "other-app" => {} } }.to_json)

    error = assert_raises(SSHKit::Runner::ExecuteError) { run_command("reboot", "-y", fixture: :with_loadbalancer) }
    assert_match "missing service app after reboot", error.message
  end

  # No owner record means this app never deployed through the LB - the
  # ordinary deploy step registers it later; there is nothing to restore.
  test "reboot skips load balancer re-registration when the service was never registered" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)
    stub_loadbalancer_registry

    run_command("reboot", "-y", fixture: :with_loadbalancer).tap do |output|
      assert_no_match(/dash-proxy deploy/, output)
    end
  end

  test "remove refuses when other apps are installed on the loadbalancer host" do
    Thread.report_on_exception = false
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)
    stub_loadbalancer_registry
    # Only the dedicated load balancer host reports other apps.
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with(:ls, ".dash/apps", "|", :wc, "-l")
      .returns("1\n")

    run_command("remove", fixture: :with_loadbalancer).tap do |output|
      assert_match "Not removing the proxy, as other apps are installed, ignore this check with dash proxy remove --force", output
      assert_no_match(/docker image prune/, output)
    end
  ensure
    Thread.report_on_exception = true
  end

  # `docker container prune` only collects stopped containers, so a load
  # balancer that is never stopped is never removed either.
  test "stop and start cover the loadbalancer host" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)

    run_command("stop", fixture: :with_loadbalancer).tap do |output|
      assert_match "docker container stop load-balancer on lb.example.com", output
    end

    run_command("start", fixture: :with_loadbalancer).tap do |output|
      assert_match "docker container start load-balancer on lb.example.com", output
    end
  end

  test "remove stops the loadbalancer before pruning it" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)
    stub_loadbalancer_registry

    run_command("remove", fixture: :with_loadbalancer).tap do |output|
      assert_match "docker container stop load-balancer on lb.example.com", output
      assert_match "docker container prune --force --filter label=org.opencontainers.image.title=dash-loadbalancer", output
    end
  end

  test "remove cleans up the loadbalancer directory" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)
    stub_loadbalancer_registry

    run_command("remove", fixture: :with_loadbalancer).tap do |output|
      assert_match "rm -r .dash/loadbalancer", output
    end
  end

  # Certificate store transfer

  test "export_certs downloads the archive from the running proxy" do
    stub_cert_container_running "dash-proxy"
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with(:docker, :exec, "dash-proxy", "dash-proxy", :export, :certs, "/home/dash-proxy/.apps-config/certs-export.tar.gz")
      .returns("Exported 3 certificates (5 domains)")
    downloads = capture_downloads

    run_command("export_certs", "certs.tar.gz").tap do |output|
      assert_match "mkdir -p .dash/proxy/apps-config", output
      assert_match "Exported 3 certificates (5 domains)", output
      assert_no_match(/docker login/, output)
      assert_match "rm .dash/proxy/apps-config/certs-export.tar.gz", output
    end

    assert_equal [ [ ".dash/proxy/apps-config/certs-export.tar.gz", "certs.tar.gz" ] ], downloads
  end

  test "export_certs falls back to a one-off container when the proxy is stopped" do
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("")
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with { |*args| args.join(" ").include?("docker run --rm --volume dash-proxy-config:/home/dash-proxy/.config/dash-proxy") && args.join(" ").include?("export certs") }
      .returns("Exported 0 certificates (0 domains)")
    downloads = capture_downloads

    run_command("export_certs", "certs.tar.gz").tap do |output|
      assert_match "docker login", output
      assert_match "Exported 0 certificates (0 domains)", output
    end

    assert_equal [ [ ".dash/proxy/apps-config/certs-export.tar.gz", "certs.tar.gz" ] ], downloads
  end

  test "export_certs targets the loadbalancer when load balancing" do
    Dash::Configuration::Proxy.any_instance.unstub(:load_balancing?)
    stub_cert_container_running "load-balancer"
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with(:docker, :exec, "load-balancer", "dash-proxy", :export, :certs, "/home/dash-proxy/.apps-config/certs-export.tar.gz")
      .returns("Exported 3 certificates (5 domains)")
    downloads = capture_downloads

    run_command("export_certs", "certs.tar.gz", fixture: :with_loadbalancer).tap do |output|
      assert_match "mkdir -p .dash/proxy/apps-config on lb.example.com", output
      assert_match "Exported 3 certificates (5 domains)", output
    end

    assert_equal [ [ ".dash/proxy/apps-config/certs-export.tar.gz", "certs.tar.gz" ] ], downloads
  end

  test "import_certs stages the source and runs the one-off importer" do
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("")
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with { |*args| args.join(" ").include?("sh -c 'cat > /tmp/kamal-cert-import && dash-proxy import certs --traefik-acme=\"/tmp/kamal-cert-import\"' < .dash/proxy/certs-import") }
      .returns("Imported: 3")
    uploads = capture_file_uploads

    run_command("import_certs", "--traefik-acme", "acme.json").tap do |output|
      assert_match "mkdir -p .dash/proxy", output
      assert_match "docker login", output
      assert_match "Imported: 3", output
      assert_match "rm .dash/proxy/certs-import", output
    end

    assert_equal [ [ "acme.json", ".dash/proxy/certs-import", "0600" ] ], uploads
  end

  test "import_certs refuses to run while the proxy is running" do
    stub_cert_container_running "dash-proxy"

    assert_raises(SSHKit::Runner::ExecuteError) do
      stdouted { Dash::Cli::Proxy.start([ "import_certs", "--archive", "certs.tar.gz", "-c", "test/fixtures/deploy_with_proxy.yml" ]) }
    end
  end

  test "import_certs verify runs against a running proxy" do
    stub_cert_container_running "dash-proxy"
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with { |*args| args.join(" ").include?("--archive=\"/tmp/kamal-cert-import\" --verify") }
      .returns("Verified 3 certificates")
    capture_file_uploads

    run_command("import_certs", "--archive", "certs.tar.gz", "--verify").tap do |output|
      assert_match "Verified 3 certificates", output
    end
  end

  test "import_certs requires exactly one source" do
    assert_raises(ArgumentError) do
      stdouted { Dash::Cli::Proxy.start([ "import_certs", "-c", "test/fixtures/deploy_with_proxy.yml" ]) }
    end

    assert_raises(ArgumentError) do
      stdouted { Dash::Cli::Proxy.start([ "import_certs", "--traefik-acme", "a", "--archive", "b", "-c", "test/fixtures/deploy_with_proxy.yml" ]) }
    end
  end

  test "import_certs rejects contradictory flags" do
    # resolver is a Traefik-import concern, force/verify are archive concerns.
    assert_raises(ArgumentError) do
      stdouted { Dash::Cli::Proxy.start([ "import_certs", "--archive", "a", "--resolver", "le", "-c", "test/fixtures/deploy_with_proxy.yml" ]) }
    end

    assert_raises(ArgumentError) do
      stdouted { Dash::Cli::Proxy.start([ "import_certs", "--traefik-acme", "a", "--force", "-c", "test/fixtures/deploy_with_proxy.yml" ]) }
    end

    assert_raises(ArgumentError) do
      stdouted { Dash::Cli::Proxy.start([ "import_certs", "--archive", "a", "--force", "--verify", "-c", "test/fixtures/deploy_with_proxy.yml" ]) }
    end
  end

  private
    def stub_cert_container_running(name)
      SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("")
      SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
        .with(:docker, :container, :ls, "--filter", "'name=^#{name}$'", "--quiet", raise_on_non_zero_exit: false)
        .returns("abc123")
    end

    def capture_downloads
      [].tap do |downloads|
        SSHKit::Backend::Printer.any_instance.stubs(:download!).with do |remote, local|
          downloads << [ remote, local ]
          true
        end
      end
    end

    # Unlike capture_uploads, the source is a local file path, not an IO.
    def capture_file_uploads
      [].tap do |uploads|
        SSHKit::Backend::Printer.any_instance.stubs(:upload!).with do |local, path, **options|
          uploads << [ local, path, options[:mode] ]
          true
        end
      end
    end

    # Records what upload! was handed rather than what the printer logged: the
    # mode is the point, and the printer does not print it.
    def capture_uploads
      [].tap do |uploads|
        SSHKit::Backend::Printer.any_instance.stubs(:upload!).with do |io, path, **options|
          uploads << [ io.string, path, options[:mode] ]
          true
        end
      end
    end

    def run_command(*command, fixture: :with_proxy)
      stdouted { Dash::Cli::Proxy.start([ *command, "-c", "test/fixtures/deploy_#{fixture}.yml" ]) }
    end

    def loadbalancer_config(fixture)
      config = Dash::Configuration.create_from(config_file: Pathname.new(File.expand_path("test/fixtures/deploy_#{fixture}.yml")))
      Dash::Configuration::Loadbalancer.new(config: config, proxy_config: config.proxy.proxy_config, secrets: config.secrets)
    end

    def loadbalancer_owner_token(fixture)
      loadbalancer_config(fixture).owner_token
    end

    # The load balancer ownership registry lives in files on the LB host; by
    # default report it as empty (nothing claimed yet).
    def stub_loadbalancer_registry(service_owner: "", run_config: "")
      lb = loadbalancer_config(:with_loadbalancer)

      SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("")
      SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
        .with(:cat, lb.service_owner_file, "2>", "/dev/null", "||", :echo, "\"\"", raise_on_non_zero_exit: false)
        .returns(service_owner)
      SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
        .with(:cat, lb.run_config_file, "2>", "/dev/null", "||", :echo, "\"\"", raise_on_non_zero_exit: false)
        .returns(run_config)
    end

    # Allow the drift-detection captures without triggering a reboot.
    def stub_no_proxy_drift
      SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
        .with(:docker, :container, :ls, "--all", "--filter", "'name=^dash-proxy$'", "--quiet", raise_on_non_zero_exit: false)
        .returns("")
      SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
        .with { |*args| args.first == :echo }
        .returns("")
    end

    # Simulate an existing proxy container running with a stale config digest.
    def stub_loadbalancer_drift
      SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("")
      SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
        .with(:docker, :container, :ls, "--all", "--filter", "'name=^load-balancer$'", "--quiet", raise_on_non_zero_exit: false)
        .returns("abc123")
      SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
        .with(:docker, :inspect, "load-balancer", "--format", Dash::Commands::Proxy::CONFIG_DIGEST_FORMAT, raise_on_non_zero_exit: false)
        .returns("stale-digest")
    end

    def stub_proxy_drift
      SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("")
      SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
        .with(:docker, :container, :ls, "--all", "--filter", "'name=^dash-proxy$'", "--quiet", raise_on_non_zero_exit: false)
        .returns("abc123")
      SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
        .with(:docker, :inspect, "dash-proxy", "--format", Dash::Commands::Proxy::CONFIG_DIGEST_FORMAT, raise_on_non_zero_exit: false)
        .returns("stale-digest")
    end

    # Swallow the deploy-lock release; the server-lock hosts get their own
    # expectations, which mocha matches ahead of this one.
    def stub_lock_release
      Dash::Cli::Proxy.any_instance.stubs(:execute_lock_release).with { |lock: nil, hosts: nil| true }.returns(true)
    end

    def expect_lock_release(host:)
      Dash::Cli::Proxy.any_instance.expects(:execute_lock_release)
        .with { |lock: nil, hosts: nil| lock&.scope == :server && hosts == host }
    end

    def assert_match_with_digest(expected, output)
      assert_match(/#{Regexp.escape(expected).sub("DIGEST", "[0-9a-f]{64}")}/, output)
    end
end
