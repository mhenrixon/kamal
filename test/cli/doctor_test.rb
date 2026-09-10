require_relative "cli_test_case"

class CliDoctorTest < CliTestCase
  PROXY_VERSION_CAPTURE_ARGS = [ :docker, :inspect, "dash-proxy", "--format '{{.Config.Image}}'", "|", :awk, "-F:", "'{print $NF}'" ]
  LEGACY_PROXY_VERSION_CAPTURE_ARGS = [ :docker, :inspect, "kamal-proxy", "--format '{{.Config.Image}}'", "|", :awk, "-F:", "'{print $NF}'" ]

  setup do
    Thread.report_on_exception = false
    # The Printer backend never sets an exit status, so execute would report
    # every check as failed. Default to success; individual tests override.
    SSHKit::Backend::Abstract.any_instance.stubs(:execute).returns(true)

    # The Dockerfile check reads the file the config points at, which for these fixtures
    # is dash's own. Pin both halves to fixtures so editing the repo's Dockerfile or its
    # .dockerignore cannot move a doctor assertion.
    stub_dockerfile "rails_multistage"
  end

  teardown do
    Thread.report_on_exception = false
  end

  test "doctor with everything healthy" do
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    run_command("doctor").tap do |output|
      assert_match "OK 1.1.1.1: connected", output
      assert_match "OK 1.1.1.1: docker is installed and running", output
      assert_match "OK 1.1.1.1: logged in to Docker Hub", output
      assert_match "dash-proxy:#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION} manifest is fetchable", output
      assert_match "OK 1.1.1.1: not running (will be started on deploy)", output
      assert_match "OK 1.1.1.1: ports 80/443 free", output
      assert_match "OK app.example.com: resolves to 1.1.1.1", output
      assert_match(/OK app\.example\.com: served certificate valid until/, output)
      assert_match "ready to deploy", output
    end
  end

  test "doctor with proxy running at current version" do
    stub_proxy_version Dash::Configuration::Proxy::Run::MINIMUM_VERSION
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    run_command("doctor").tap do |output|
      assert_match "OK 1.1.1.1: #{Dash::Configuration::Proxy::Run::MINIMUM_VERSION} (minimum #{Dash::Configuration::Proxy::Run::MINIMUM_VERSION})", output
      assert_match "OK 1.1.1.1: ports 80/443 held by the running dash-proxy", output
    end
  end

  # An old version the deploy would not touch — the config pins it, so there is
  # no drift for `proxy boot` to converge — stays a hard failure.
  test "doctor with proxy version too old and no drift to converge it" do
    stub_proxy_version "v0.0.1"
    stub_proxy_drift false
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    exception = assert_raises(Dash::Cli::DoctorError) { run_command("doctor") }
    assert_includes exception.message, "v0.0.1 is older than the minimum #{Dash::Configuration::Proxy::Run::MINIMUM_VERSION}"
  end

  # A MINIMUM_VERSION bump moves the expected config digest, so a merely-stale
  # proxy reads as drifted and `proxy boot` reboots it during the very deploy
  # this doctor gates. Failing here would block the deploy that fixes it.
  test "doctor passes an old proxy that the next deploy reboots onto the new version" do
    stub_proxy_version "v0.0.1"
    stub_proxy_drift true
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    run_command("doctor").tap do |output|
      assert_match "OK 1.1.1.1: v0.0.1 is older than the minimum #{Dash::Configuration::Proxy::Run::MINIMUM_VERSION}; the next deploy reboots the proxy to update it", output
      assert_match "ready to deploy", output
    end
  end

  # With reboot_on_deploy disabled the deploy only warns about drift, so the
  # stale proxy would survive it — that still needs an operator.
  test "doctor fails an old proxy when automatic reboots are disabled" do
    stub_proxy_version "v0.0.1"
    stub_proxy_drift true
    Dash::Configuration::Proxy.any_instance.stubs(:reboot_on_deploy?).returns(false)
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    exception = assert_raises(Dash::Cli::DoctorError) { run_command("doctor") }
    assert_includes exception.message, "run `dash proxy reboot` to update"
  end

  # A host that has not yet been through the stage-3c rename is still running
  # kamal-proxy, which holds 80/443. Reporting that as "in use by another
  # process" fails the doctor and blocks the very deploy that would migrate it —
  # which is what broke the first real 4.0.0 docs deploy.
  test "doctor treats a running legacy proxy as the port holder, not a foreign process" do
    stub_proxy_version nil, legacy: Dash::Configuration::Proxy::Run::MINIMUM_VERSION
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with { |*args| args.first == :ss }
      .returns("LISTEN 0 4096 0.0.0.0:80 0.0.0.0:*")
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    run_command("doctor").tap do |output|
      assert_match "held by the running kamal-proxy", output
      assert_match "replaced on the next deploy", output
      assert_no_match(/already in use by another process/, output)
      assert_match "ready to deploy", output
    end
  end

  # The version check should name what is actually running, rather than
  # reporting "not running" because it only ever looked at dash-proxy.
  test "doctor reports a running legacy proxy by name" do
    stub_proxy_version nil, legacy: Dash::Configuration::Proxy::Run::MINIMUM_VERSION
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    run_command("doctor").tap do |output|
      assert_match "kamal-proxy", output
      assert_match(/renamed to dash-proxy on the next deploy/, output)
    end
  end

  # With no proxy of either name, an occupied port is still a real failure.
  test "doctor with ports in use" do
    stub_proxy_version nil
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with { |*args| args.first == :ss }
      .returns("LISTEN 0 4096 0.0.0.0:80 0.0.0.0:*")
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    exception = assert_raises(Dash::Cli::DoctorError) { run_command("doctor") }
    assert_includes exception.message, "80, 443 already in use by another process"
  end

  test "doctor with unresolvable domain" do
    stub_domain_resolution to: []
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    exception = assert_raises(Dash::Cli::DoctorError) { run_command("doctor") }
    assert_includes exception.message, "app.example.com: does not resolve"
  end

  test "doctor with domain resolving elsewhere warns" do
    stub_domain_resolution to: [ "5.5.5.5" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    run_command("doctor").tap do |output|
      assert_match "WARN app.example.com: resolves to 5.5.5.5, expected one of 1.1.1.1", output
      assert_match "ready to deploy", output
    end
  end

  # "does not resolve" and "resolves elsewhere" are the two states a DNS cutover
  # passes through, and in both an ACME certificate simply cannot be issued yet.
  # Saying so — and that the proxy picks it up by itself — is the difference
  # between an operator waiting confidently and asking someone whether it broke.
  test "doctor explains that an unresolvable ACME domain cannot be certified yet" do
    stub_domain_resolution to: []
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    exception = assert_raises(Dash::Cli::DoctorError) { run_command("doctor") }
    assert_includes exception.message, "app.example.com: does not resolve"
    assert_includes exception.message, "no certificate can be issued until it points here"
    assert_includes exception.message, "the proxy issues automatically once it does"
  end

  test "doctor explains the certificate wait when an ACME domain resolves elsewhere" do
    stub_domain_resolution to: [ "5.5.5.5" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    run_command("doctor").tap do |output|
      assert_match "WARN app.example.com: resolves to 5.5.5.5, expected one of 1.1.1.1", output
      assert_match "no certificate can be issued until it points here", output
    end
  end

  # A custom certificate is supplied by the operator, so DNS has no bearing on
  # whether it exists. Promising automatic issuance there would be a lie.
  test "doctor does not promise issuance for a custom certificate" do
    stub_domain_resolution to: [ "5.5.5.5" ]
    stub_custom_certificate expiring: Time.now + (90 * 86_400)

    run_command("doctor").tap do |output|
      assert_match "WARN app.example.com: resolves to 5.5.5.5", output
      assert_no_match(/no certificate can be issued/, output)
    end
  end

  test "doctor with expired custom certificate" do
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_custom_certificate expiring: Time.now - 86_400

    exception = assert_raises(Dash::Cli::DoctorError) { run_command("doctor") }
    assert_includes exception.message, "configured certificate expired on"
  end

  test "doctor with certificate expiring soon warns" do
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (5 * 86_400)

    run_command("doctor").tap do |output|
      assert_match(/WARN app\.example\.com: served certificate expires in \d+ days/, output)
      assert_match "ready to deploy", output
    end
  end

  test "doctor with unreachable tls endpoint warns" do
    stub_domain_resolution to: [ "1.1.1.1" ]
    Dash::Cli::Doctor::EndpointChecks.any_instance.stubs(:peer_certificate)
      .raises(Errno::ECONNREFUSED.new("Connection refused"))

    run_command("doctor").tap do |output|
      assert_match "WARN app.example.com: could not check TLS", output
      assert_match "ready to deploy", output
    end
  end

  # The config-time sleep/docker_socket check covers the *current* config; a
  # proxy booted before the socket was added silently lacks the mount until
  # the next reboot, and the failure mode is one hung request when a sleeping
  # service never wakes. The doctor inspects what is actually mounted.
  test "doctor reports a mounted docker socket" do
    stub_proxy_version Dash::Configuration::Proxy::Run::MINIMUM_VERSION
    stub_proxy_mounts "/home/dash-proxy/.config/dash-proxy\n/var/run/docker.sock"
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    run_command("doctor", fixture: "deploy_with_doctor_socket").tap do |output|
      assert_match "OK 1.1.1.1: docker socket /var/run/docker.sock is mounted", output
    end
  end

  test "doctor fails when sleep is configured but the running proxy lacks the socket mount" do
    stub_proxy_version Dash::Configuration::Proxy::Run::MINIMUM_VERSION
    stub_proxy_mounts "/home/dash-proxy/.config/dash-proxy"
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    exception = assert_raises(Dash::Cli::DoctorError) { run_command("doctor", fixture: "deploy_with_doctor_socket") }
    assert_includes exception.message, "no /var/run/docker.sock mount"
    assert_includes exception.message, "dash proxy reboot"
  end

  # Without sleep nothing hangs yet, so a missing mount is drift, not breakage.
  test "doctor warns when the socket is configured without sleep and not mounted" do
    stub_proxy_version Dash::Configuration::Proxy::Run::MINIMUM_VERSION
    stub_proxy_mounts "/home/dash-proxy/.config/dash-proxy"
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    run_command("doctor", fixture: "deploy_with_doctor_socket_only").tap do |output|
      assert_match "WARN 1.1.1.1: the running dash-proxy has no /var/run/docker.sock mount", output
      assert_match "ready to deploy", output
    end
  end

  # Root-equivalent access the config no longer asks for deserves a flag.
  test "doctor warns about a mounted socket the config no longer asks for" do
    stub_proxy_version Dash::Configuration::Proxy::Run::MINIMUM_VERSION
    stub_proxy_mounts "/home/dash-proxy/.config/dash-proxy\n/var/run/docker.sock"
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    run_command("doctor").tap do |output|
      assert_match "WARN 1.1.1.1: the running dash-proxy mounts /var/run/docker.sock but the config no longer asks for it", output
      assert_match "ready to deploy", output
    end
  end

  test "doctor reports a boot-time socket when the proxy is not running" do
    stub_proxy_version nil
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with { |*args| args.first == :ss }
      .returns("")
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    run_command("doctor", fixture: "deploy_with_doctor_socket").tap do |output|
      assert_match "OK 1.1.1.1: docker socket /var/run/docker.sock will be mounted on boot", output
    end
  end

  test "doctor stays quiet about sockets when none is configured or mounted" do
    stub_proxy_version Dash::Configuration::Proxy::Run::MINIMUM_VERSION
    stub_proxy_mounts "/home/dash-proxy/.config/dash-proxy"
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    run_command("doctor").tap do |output|
      assert_match "OK 1.1.1.1: no docker socket configured or mounted", output
    end
  end

  test "doctor with local registry skips login" do
    run_command("doctor", fixture: "deploy_with_local_registry").tap do |output|
      assert_match "OK 1.1.1.1: local registry, no login required", output
      assert_match "OK 1.1.1.2: local registry, no login required", output
    end
  end

  test "doctor with unreachable host reports ssh failure" do
    SSHKit::Backend::Abstract.any_instance.stubs(:execute)
      .raises(SocketError.new("getaddrinfo: nodename nor servname provided, or not known"))
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    exception = assert_raises(Dash::Cli::DoctorError) { run_command("doctor") }
    assert_includes exception.message, "SSH"
    assert_includes exception.message, "getaddrinfo"
  end

  test "doctor reports the readiness source of every role" do
    run_command("doctor", fixture: "deploy_with_readiness_sources").tap do |output|
      assert_match "Readiness", output
      assert_match "OK web: dash-proxy health check /healthz", output
      assert_match "OK pulse: docker healthcheck (options: health-cmd)", output
      assert_match "OK listener: healthcheck /readyz:7434", output
      assert_match "OK ticker: healthcheck (custom cmd)", output
      assert_match "OK prober: healthcheck exec probe (bin/ready-check)", output
      assert_no_match(/WARN prober/, output)
    end
  end

  test "doctor warns about a role with no readiness definition without failing" do
    run_command("doctor", fixture: "deploy_with_readiness_sources").tap do |output|
      assert_match "WARN workers: no healthcheck — the old container stops 7s after the new one starts", output
      assert_match "add a `healthcheck:` block, or opt out with `healthcheck: false`", output
      assert_match "ready to deploy", output
    end
  end

  test "doctor accepts a role that explicitly opted out of a healthcheck" do
    run_command("doctor", fixture: "deploy_with_readiness_sources").tap do |output|
      assert_match "OK silent: healthcheck: false — accepted 2s after the container starts", output
      assert_no_match(/WARN silent/, output)
    end
  end

  test "doctor still reports readiness when the hosts are unreachable" do
    SSHKit::Backend::Abstract.any_instance.stubs(:execute)
      .raises(SocketError.new("getaddrinfo: nodename nor servname provided, or not known"))

    output = stdouted do
      assert_raises(Dash::Cli::DoctorError) do
        with_argv([ "doctor", "-c", "test/fixtures/deploy_with_readiness_sources.yml" ]) { Dash::Cli::Main.start }
      end
    end

    assert_match "WARN workers: no healthcheck", output
  end

  test "doctor reports a Dockerfile with nothing to say" do
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    run_command("doctor").tap do |output|
      assert_match "Dockerfile", output
      assert_match "OK test/fixtures/dockerfiles/rails_multistage.Dockerfile: no findings", output
      assert_match "Everything looks ready to deploy", output
    end
  end

  # Advice is advice: a warning is worth an operator's attention, an informational finding
  # is worth printing, and neither is a reason to refuse the deploy.
  test "doctor warns about Dockerfile findings without failing the check" do
    stub_dockerfile "naive_single_stage"
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    run_command("doctor").tap do |output|
      assert_match "WARN test/fixtures/dockerfiles/naive_single_stage.Dockerfile:5: COPY . . runs before `bundle install`", output
      assert_match "[copy-before-install]", output
      assert_match "OK test/fixtures/dockerfiles/naive_single_stage.Dockerfile:1: the final stage has no USER", output
      assert_match "warning(s) to review", output
    end
  end

  test "doctor honours the report ignore list" do
    stub_dockerfile "naive_single_stage"
    Dash::Configuration::Report.any_instance.stubs(:ignore).returns([ "copy-before-install", "root-user" ])
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    run_command("doctor").tap do |output|
      assert_no_match(/copy-before-install/, output)
      assert_no_match(/root-user/, output)
      assert_match "[latest-base]", output
    end
  end

  # The same condition Dash::Commands::Builder::Base#build_dockerfile raises on, caught
  # before the operator has spent a deploy finding out.
  test "doctor fails when the Dockerfile the build needs is missing" do
    stub_dockerfile "nonexistent"
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    exception = assert_raises(Dash::Cli::DoctorError) { run_command("doctor") }
    assert_includes exception.message, "not found — `dash build push` fails with Missing"
  end

  test "a Dockerfile that cannot be analysed warns instead of crashing the doctor" do
    Dash::Dockerfile::Parser.stubs(:parse).raises(ArgumentError, "boom")
    stub_domain_resolution to: [ "1.1.1.1" ]
    stub_served_certificate expiring: Time.now + (90 * 86_400)

    run_command("doctor").tap do |output|
      assert_match "could not be analysed (ArgumentError: boom)", output
      assert_match "warning(s) to review", output
    end
  end

  private
    def stub_dockerfile(name)
      Dash::Configuration::Builder.any_instance.stubs(:dockerfile).returns("test/fixtures/dockerfiles/#{name}.Dockerfile")
      Dash::Configuration::Builder.any_instance.stubs(:context).returns("test/fixtures/dockerfiles/context")
    end

    def run_command(*command, fixture: "deploy_with_doctor")
      with_argv([ *command, "-c", "test/fixtures/#{fixture}.yml" ]) do
        stdouted { Dash::Cli::Main.start }
      end
    end

    def stub_proxy_version(version, legacy: nil)
      SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
        .with(*PROXY_VERSION_CAPTURE_ARGS)
        .returns(version.to_s)

      SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
        .with(*LEGACY_PROXY_VERSION_CAPTURE_ARGS)
        .returns(legacy.to_s)

      # A running proxy also gets its mounts inspected; default to none so
      # tests that do not care about the socket check stay quiet. Call
      # stub_proxy_mounts after this to override.
      stub_proxy_mounts ""
    end

    def stub_proxy_drift(drifted)
      Dash::Cli::Proxy::Drift.any_instance.stubs(:drifted?).returns(drifted)
    end

    def stub_proxy_mounts(destinations)
      SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
        .with(:docker, :inspect, "dash-proxy", "--format", "'{{range .Mounts}}{{println .Destination}}{{end}}'", raise_on_non_zero_exit: false)
        .returns(destinations)
    end

    def stub_domain_resolution(to:)
      Resolv.stubs(:getaddresses).with("app.example.com").returns(to)
    end

    def stub_served_certificate(expiring:)
      Dash::Cli::Doctor::EndpointChecks.any_instance.stubs(:peer_certificate)
        .returns(generate_certificate(not_after: expiring))
    end

    def stub_custom_certificate(expiring:)
      Dash::Configuration::Proxy.any_instance.stubs(:custom_ssl_certificate?).returns(true)
      Dash::Configuration::Proxy.any_instance.stubs(:certificate_pem_content)
        .returns(generate_certificate(not_after: expiring).to_pem)
    end

    def generate_certificate(not_after:)
      key = OpenSSL::PKey::RSA.new(2048)
      certificate = OpenSSL::X509::Certificate.new
      certificate.version = 2
      certificate.serial = 1
      certificate.subject = OpenSSL::X509::Name.parse("/CN=app.example.com")
      certificate.issuer = certificate.subject
      certificate.public_key = key.public_key
      certificate.not_before = Time.now - 3600
      certificate.not_after = not_after
      certificate.sign(key, OpenSSL::Digest::SHA256.new)
      certificate
    end
end
