require_relative "cli_test_case"

class CliAppTest < CliTestCase
  test "boot" do
    stub_running
    run_command("boot").tap do |output|
      assert_match "docker tag dhh/app:latest dhh/app:latest", output
      assert_match /docker run --detach --restart unless-stopped --name app-web-latest --network dash --hostname 1.1.1.1-[0-9a-f]{12} /, output
      assert_match "docker container ls --all --filter 'name=^app-web-123$' --quiet | xargs docker stop", output
    end

    # Printed by deploy's print_runtime, not by app boot itself — assert the entry it records.
    # `app boot` takes the deploy lock, which records a phase of its own, so this is not the only line.
    assert DASH.timings.lines.any? { |line| line.match?(/\A    web 1\.1\.1\.1\s+\d+\.\ds\s+\d+ ssh\s+\d+\.\ds \(healthy after \d+\.\ds\)\z/) },
      DASH.timings.lines.inspect
  end

  test "boot will rename if same version is already running" do
    Object.any_instance.stubs(:sleep)
    run_command("details") # Preheat Kamal const

    stub_boot_state clash: "12345678", running: "123"

    SSHKit::Backend::Abstract.any_instance.expects(:capture_with_info)
      .with(:docker, :container, :ls, "--all", "--filter", "'name=^app-web-latest$'", "--quiet")
      .returns("12345678") # running version

    run_command("boot").tap do |output|
      assert_match /Renaming container .* to .* as already deployed on 1.1.1.1/, output # Rename
      assert_match /docker rename app-web-latest app-web-latest_replaced_[0-9a-f]{16}/, output
      assert_match /docker run --detach --restart unless-stopped --name app-web-latest --network dash --hostname 1.1.1.1-[0-9a-f]{12} /, output
      assert_match "docker container ls --all --filter 'name=^app-web-123$' --quiet | xargs docker stop", output
    end
  ensure
    Thread.report_on_exception = true
  end

  # The clash check and the running-version read share one round trip, so the running
  # version is now read BEFORE the clashing container is renamed. When they are the same
  # container, the old version to stop is the name it was renamed to - stopping the name
  # that was read would stop the container this boot just started.
  test "boot stops the renamed container when the version being deployed was the running one" do
    Object.any_instance.stubs(:sleep)
    run_command("details") # Preheat Kamal const

    stub_boot_state clash: "12345678", running: "latest"

    SSHKit::Backend::Abstract.any_instance.expects(:capture_with_info)
      .with(:docker, :container, :ls, "--all", "--filter", "'name=^app-web-latest$'", "--quiet")
      .returns("12345678")

    run_command("boot").tap do |output|
      renamed = output[/docker rename app-web-latest (app-web-latest_replaced_[0-9a-f]{16})/, 1]
      assert renamed, output

      assert_match "docker container ls --all --filter 'name=^#{renamed}$' --quiet | xargs docker stop", output
      assert_no_match(/'name=\^app-web-latest\$' --quiet \| xargs docker stop/, output)
    end
  ensure
    Thread.report_on_exception = true
  end

  test "boot reads the clash check and the running version in a single round trip" do
    stub_running

    commands = []
    SSHKit::Backend::Printer.any_instance.stubs(:execute_command).with { |cmd| commands << cmd.to_command; true }

    run_command("boot")

    assert_equal 0, commands.count { |command| command.include?("docker ps --latest") },
      "current_running_version should no longer be a round trip of its own"
  end

  # An audit line is a write to a file the action it describes is about to change. Folding
  # it into the same shell string keeps "audit before action" and halves the round trips.
  test "boot records the audit line in the same round trip as the action" do
    stub_running

    run_command("boot").tap do |output|
      assert_match %r{\[web\] Booted app version latest" >> \.dash/app-audit\.log && mkdir -p \.dash/apps/app/env/roles}, output
      assert_match %r{Tagging dhh/app:latest as the latest image" >> \.dash/app-audit\.log && docker tag dhh/app:latest dhh/app:latest}, output
    end
  end

  test "boot uses group strategy when specified" do
    Dash::Cli::App.any_instance.stubs(:on).with("1.1.1.1").twice
    Dash::Cli::App.any_instance.stubs(:on).with([ "1.1.1.1", "1.1.1.2", "1.1.1.3", "1.1.1.4" ]).times(3)

    # Strategy is used when booting the containers
    Dash::Cli::App.any_instance.expects(:on).with([ "1.1.1.1", "1.1.1.2", "1.1.1.3" ]).with_block_given
    Dash::Cli::App.any_instance.expects(:on).with([ "1.1.1.4" ]).with_block_given
    # Two groups, so the wait paces the first against the second — and stops there.
    Object.any_instance.expects(:sleep).with(2).once

    Dash::Commands::Hook.any_instance.stubs(:hook_exists?).returns(true)

    run_command("boot", config: :with_boot_strategy, host: nil).tap do |output|
      assert_hook_ran "pre-app-boot", output, count: 2
      assert_hook_ran "post-app-boot", output, count: 2
    end
  end

  # `wait` paces one group against the next. After the last group there is nothing left
  # to boot, so sleeping is pure deploy latency.
  test "boot does not wait after the final host group" do
    Dash::Cli::App.any_instance.stubs(:on)

    Object.any_instance.expects(:sleep).with(2).times(3)

    run_command("boot", config: :with_boot_limit_one, host: nil)
  end

  test "boot does not wait at all when a single group covers every host" do
    Dash::Cli::App.any_instance.stubs(:on)

    Object.any_instance.expects(:sleep).with(2).never

    run_command("boot", config: :with_boot_wait_only, host: nil)
  end

  test "a percentage boot limit groups by app hosts, not accessory hosts" do
    # Four app hosts, four accessory hosts. Accessories are never booted here, so 25% is
    # one app host per group — counting all eight would boot two at a time.
    Dash::Cli::App.any_instance.stubs(:on).with("1.1.1.1")
    Dash::Cli::App.any_instance.stubs(:on).with([ "1.1.1.1", "1.1.1.2", "1.1.1.3", "1.1.1.4" ])
    Dash::Cli::App.any_instance.stubs(:on).with(%w[ 1.1.1.1 1.1.1.2 1.1.1.3 1.1.1.4 1.1.1.5 1.1.1.6 1.1.1.7 1.1.1.8 ])

    [ "1.1.1.1", "1.1.1.2", "1.1.1.3", "1.1.1.4" ].each do |host|
      Dash::Cli::App.any_instance.expects(:on).with([ host ]).with_block_given
    end

    run_command("boot", config: :with_percentage_boot_limit, host: nil)
  end

  test "a percentage boot limit narrows with --roles" do
    # web only: 25% of two hosts clamps to one, not 25% of the whole file.
    Dash::Cli::App.any_instance.stubs(:on).with("1.1.1.1")
    Dash::Cli::App.any_instance.stubs(:on).with([ "1.1.1.1", "1.1.1.2" ])
    Dash::Cli::App.any_instance.stubs(:on).with(%w[ 1.1.1.1 1.1.1.2 1.1.1.3 1.1.1.4 1.1.1.5 1.1.1.6 1.1.1.7 1.1.1.8 ])

    Dash::Cli::App.any_instance.expects(:on).with([ "1.1.1.1" ]).with_block_given
    Dash::Cli::App.any_instance.expects(:on).with([ "1.1.1.2" ]).with_block_given

    run_command("boot", "--roles", "web", config: :with_percentage_boot_limit, host: nil)
  end

  test "boot with a canary boots the first primary host alone, then the rest together" do
    all_hosts = [ "1.1.1.1", "1.1.1.2", "1.1.1.3", "1.1.1.4" ]
    Dash::Cli::App.any_instance.stubs(:on).with("1.1.1.1")
    Dash::Cli::App.any_instance.stubs(:on).with(all_hosts)

    Dash::Cli::App.any_instance.expects(:on).with([ "1.1.1.1" ]).with_block_given
    Dash::Cli::App.any_instance.expects(:on).with([ "1.1.1.2", "1.1.1.3", "1.1.1.4" ]).with_block_given
    # Two groups: one gap, paced by the wait.
    Object.any_instance.expects(:sleep).with(2).once

    Dash::Commands::Hook.any_instance.stubs(:hook_exists?).returns(true)

    run_command("boot", config: :with_boot_canary, host: nil).tap do |output|
      assert_hook_ran "pre-app-boot", output, count: 2
      assert_hook_ran "post-app-boot", output, count: 2
    end
  end

  test "a canary with a limit slices the remaining hosts" do
    all_hosts = [ "1.1.1.1", "1.1.1.2", "1.1.1.3", "1.1.1.4" ]
    Dash::Cli::App.any_instance.stubs(:on).with("1.1.1.1")
    Dash::Cli::App.any_instance.stubs(:on).with(all_hosts)

    Dash::Cli::App.any_instance.expects(:on).with([ "1.1.1.1" ]).with_block_given
    Dash::Cli::App.any_instance.expects(:on).with([ "1.1.1.2", "1.1.1.3" ]).with_block_given
    Dash::Cli::App.any_instance.expects(:on).with([ "1.1.1.4" ]).with_block_given

    run_command("boot", config: :with_boot_canary_and_limit, host: nil)
  end

  test "a canary narrows with --roles" do
    # workers only: no primary host in the run, so there is no canary and a single group.
    # Every fan-out (assets, the one boot group, the latest tag) covers that single host.
    Dash::Cli::App.any_instance.stubs(:on).with("1.1.1.4")

    Dash::Cli::App.any_instance.expects(:on).with([ "1.1.1.4" ]).with_block_given.at_least_once
    Object.any_instance.expects(:sleep).never

    run_command("boot", "--roles", "workers", config: :with_boot_canary, host: nil)
  end

  test "a failing canary stops the deploy before the next group boots" do
    Dash::Cli::App.any_instance.stubs(:on).with("1.1.1.1")
    Dash::Cli::App.any_instance.stubs(:on).with([ "1.1.1.1", "1.1.1.2", "1.1.1.3", "1.1.1.4" ])

    Dash::Cli::App.any_instance.expects(:on).with([ "1.1.1.1" ]).with_block_given
      .raises(SSHKit::Runner::ExecuteError.new(Dash::Cli::BootError.new("canary is unhealthy")))
    Dash::Cli::App.any_instance.expects(:on).with([ "1.1.1.2", "1.1.1.3", "1.1.1.4" ]).never
    Object.any_instance.expects(:sleep).never

    assert_raises(SSHKit::Runner::ExecuteError) do
      run_command("boot", config: :with_boot_canary, host: nil)
    end
  end

  test "a canary opens the barrier for the roles booting after it" do
    Object.any_instance.stubs(:sleep)

    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("123") # container id
    stub_boot_state clash: "12345678", running: "123", expect: false

    SSHKit::Backend::Abstract.any_instance.expects(:capture_with_info)
      .with(:docker, :container, :ls, "--all", "--filter", "'name=^app-workers-latest$'", "--quiet", "|", :xargs, :docker, :inspect, "--format", Dash::Commands::Base::DOCKER_HEALTH_STATUS_FORMAT)
      .returns("no-healthcheck:running").at_least_once # workers health check

    run_command("boot", config: :with_boot_canary, host: nil).tap do |output|
      assert_match "First web container is healthy on 1.1.1.1, booting any other roles", output
      assert_match "First web container is healthy, booting workers on 1.1.1.4", output
    end
  end

  test "boot without parallel roles" do
    # Without parallel_roles: on() called with all hosts, roles sequential per host
    Dash::Cli::App.any_instance.expects(:on).with("1.1.1.1").with_block_given.twice
    Dash::Cli::App.any_instance.expects(:on).with([ "1.1.1.1", "1.1.1.2", "1.1.1.3" ]).with_block_given.times(4)

    run_command("boot", config: :without_parallel_roles, host: nil)
  end

  test "boot with parallel roles" do
    # With parallel_roles: each role gets its own on() call, unpaced
    Dash::Cli::App.any_instance.expects(:on).with("1.1.1.1").with_block_given.twice
    Dash::Cli::App.any_instance.expects(:on).with([ "1.1.1.1", "1.1.1.2", "1.1.1.3" ]).with_block_given.times(3)
    Dash::Cli::App.any_instance.expects(:on).with([ "1.1.1.1", "1.1.1.2" ], {}).with_block_given
    Dash::Cli::App.any_instance.expects(:on).with([ "1.1.1.1", "1.1.1.3" ], {}).with_block_given

    run_command("boot", config: :with_parallel_roles, host: nil)
  end

  test "boot paces only the role that declares its own boot limit" do
    all_hosts = [ "1.1.1.1", "1.1.1.2", "1.1.1.3", "1.1.1.4" ]
    Dash::Cli::App.any_instance.expects(:on).with("1.1.1.1").with_block_given.twice
    Dash::Cli::App.any_instance.expects(:on).with(all_hosts).with_block_given.times(3)

    # The role-level boot forces role-first iteration even though parallel_roles is unset,
    # and only that role's hosts get a sequential runner — web still boots in parallel.
    Dash::Cli::App.any_instance.expects(:on).with([ "1.1.1.1", "1.1.1.2" ], {}).with_block_given
    Dash::Cli::App.any_instance.expects(:on).with([ "1.1.1.3", "1.1.1.4" ], { in: :sequence, wait: 0 }).with_block_given

    run_command("boot", config: :with_role_boot, host: nil)
  end

  test "boot errors don't leave lock in place" do
    Dash::Cli::App.any_instance.expects(:using_version).raises(RuntimeError)

    assert_not DASH.holding_lock?
    assert_raises(RuntimeError) do
      stderred { run_command("boot") }
    end
    assert_not DASH.holding_lock?
  end

  test "boot with assets" do
    Object.any_instance.stubs(:sleep)

    # The assets step reads the running version on its own, before the boot does.
    SSHKit::Backend::Abstract.any_instance.expects(:capture_with_info)
      .with(:sh, "-c", "'docker ps --latest --format '\\''{{.Names}}'\\'' --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting --filter ancestor=$(docker image ls --filter reference=dhh/app:latest --format '\\''{{.ID}}'\\'') ; docker ps --latest --format '\\''{{.Names}}'\\'' --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting'", "|", :head, "-1", "|", "while read line; do echo ${line#app-web-}; done", raise_on_non_zero_exit: false)
      .returns("123") # old version

    stub_boot_state clash: "12345678", running: "123"

    SSHKit::Backend::Abstract.any_instance.expects(:capture_with_info)
      .with(:docker, :container, :ls, "--all", "--filter", "'name=^app-web-latest$'", "--quiet")
      .returns("12345678") # running version

    run_command("boot", config: :with_assets).tap do |output|
      assert_match "docker tag dhh/app:latest dhh/app:latest", output
      assert_match "/usr/bin/env mkdir -p .dash/apps/app/assets/volumes/web-latest ; cp -rnT .dash/apps/app/assets/extracted/web-latest .dash/apps/app/assets/volumes/web-latest ; cp -rnT .dash/apps/app/assets/extracted/web-latest .dash/apps/app/assets/volumes/web-123 || true ; cp -rnT .dash/apps/app/assets/extracted/web-123 .dash/apps/app/assets/volumes/web-latest || true", output
      assert_match "/usr/bin/env mkdir -p .dash/apps/app/assets/extracted/web-latest && docker container rm app-web-assets 2> /dev/null || true && docker container create --name app-web-assets dhh/app:latest && docker container cp -L app-web-assets:/public/assets/. .dash/apps/app/assets/extracted/web-latest && docker container rm app-web-assets", output
      assert_match /docker run --detach --restart unless-stopped --name app-web-latest --network dash --hostname 1.1.1.1-[0-9a-f]{12} /, output
      assert_match "docker container ls --all --filter 'name=^app-web-123$' --quiet | xargs docker stop", output
      assert_match "/usr/bin/env find .dash/apps/app/assets/extracted -maxdepth 1 -name 'web-*' ! -name web-latest -exec rm -rf \"{}\" + ; find .dash/apps/app/assets/volumes -maxdepth 1 -name 'web-*' ! -name web-latest -exec rm -rf \"{}\" +", output
    end
  end

  test "boot with host tags" do
    Object.any_instance.stubs(:sleep)

    stub_boot_state clash: "12345678", running: "123"

    SSHKit::Backend::Abstract.any_instance.expects(:capture_with_info)
      .with(:docker, :container, :ls, "--all", "--filter", "'name=^app-web-latest$'", "--quiet")
      .returns("12345678") # running version

    run_command("boot", config: :with_env_tags).tap do |output|
      assert_match "docker tag dhh/app:latest dhh/app:latest", output
      assert_match %r{docker run --detach --restart unless-stopped --name app-web-latest --network dash --hostname 1.1.1.1-[0-9a-f]{12} --env KAMAL_CONTAINER_NAME="app-web-latest" --env KAMAL_VERSION="latest" --env KAMAL_HOST="1.1.1.1" --env TEST="root" --env EXPERIMENT="disabled" --env SITE="site1"}, output
      assert_match "docker container ls --all --filter 'name=^app-web-123$' --quiet | xargs docker stop", output
    end
  end

  test "boot with web barrier opened" do
    Object.any_instance.stubs(:sleep)

    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("123") # container id
    stub_boot_state clash: "12345678", running: "123", expect: false

    SSHKit::Backend::Abstract.any_instance.expects(:capture_with_info)
      .with(:docker, :container, :ls, "--all", "--filter", "'name=^app-workers-latest$'", "--quiet", "|", :xargs, :docker, :inspect, "--format", Dash::Commands::Base::DOCKER_HEALTH_STATUS_FORMAT)
      .returns("no-healthcheck:running").at_least_once # workers health check

    run_command("boot", config: :with_roles, host: nil).tap do |output|
      assert_match "Waiting for the first healthy web container before booting workers on 1.1.1.3...", output
      assert_match "Waiting for the first healthy web container before booting workers on 1.1.1.4...", output
      assert_match "First web container is healthy, booting workers on 1.1.1.3", output
      assert_match "First web container is healthy, booting workers on 1.1.1.4", output
    end
  end

  test "a role-level boot still waits for the first healthy web container" do
    # Pacing a role flips iteration from host-first to role-first. The barrier is what
    # guarantees the primary role goes first, and it has to survive that flip.
    Object.any_instance.stubs(:sleep)

    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("123") # container id
    stub_boot_state clash: "12345678", running: "123", expect: false

    SSHKit::Backend::Abstract.any_instance.expects(:capture_with_info)
      .with(:docker, :container, :ls, "--all", "--filter", "'name=^app-workers-latest$'", "--quiet", "|", :xargs, :docker, :inspect, "--format", Dash::Commands::Base::DOCKER_HEALTH_STATUS_FORMAT)
      .returns("no-healthcheck:running").at_least_once # workers health check

    run_command("boot", config: :with_role_boot, host: nil).tap do |output|
      assert_match "Waiting for the first healthy web container before booting workers on 1.1.1.3...", output
      assert_match "Waiting for the first healthy web container before booting workers on 1.1.1.4...", output
      assert_match "First web container is healthy, booting workers on 1.1.1.3", output
      assert_match "First web container is healthy, booting workers on 1.1.1.4", output
    end
  end

  test "boot with web barrier closed" do
    Thread.report_on_exception = false

    Object.any_instance.stubs(:sleep)

    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("123") # container id
    stub_boot_state clash: "12345678", running: "123", expect: false

    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with(:docker, :container, :ls, "--all", "--filter", "'name=^app-web-latest$'", "--quiet", "|", "xargs docker logs --timestamps 2>&1")
      .returns("Web exited with status 1")

    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with(:docker, :container, :ls, "--all", "--filter", "'name=^app-web-latest$'", "--quiet", "|", :xargs, :docker, :inspect, "--format", "'{{json .State.Health}}'")
      .returns('{"Status":"unhealthy","FailingStreak":3}')

    SSHKit::Backend::Abstract.any_instance.stubs(:execute).returns("")
    SSHKit::Backend::Abstract.any_instance.stubs(:execute)
      .with(:docker, :container, :ls, "--all", "--filter", "'name=^app-web-latest$'", "--quiet", "|", :xargs, :docker, :stop, raise_on_non_zero_exit: false)
    SSHKit::Backend::Abstract.any_instance.expects(:execute)
      .with(:docker, :exec, "dash-proxy", "dash-proxy", :deploy, "app-web", "--target=\"123:80\"", "--deploy-timeout=\"1s\"", "--drain-timeout=\"30s\"", "--buffer-requests", "--buffer-responses", "--log-request-header=\"Cache-Control\"", "--log-request-header=\"Last-Modified\"", "--log-request-header=\"User-Agent\"").raises(SSHKit::Command::Failed.new("Failed to deploy"))

    stderred do
      run_command("boot", config: :with_roles, host: nil, allow_execute_error: true).tap do |output|
        assert_match "Waiting for the first healthy web container before booting workers on 1.1.1.3...", output
        assert_match "Waiting for the first healthy web container before booting workers on 1.1.1.4...", output
        assert_match "First web container is unhealthy, not booting workers on 1.1.1.3", output
        assert_match "First web container is unhealthy, not booting workers on 1.1.1.4", output
        assert_match "Web exited with status 1", output
        assert_match "FailingStreak", output
      end
    end
  ensure
    Thread.report_on_exception = true
  end

  test "boot with worker errors" do
    Thread.report_on_exception = false

    Object.any_instance.stubs(:sleep)

    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("123") # container id
    stub_boot_state clash: "12345678", running: "123", expect: false

    SSHKit::Backend::Abstract.any_instance.expects(:capture_with_info)
      .with(:docker, :container, :ls, "--all", "--filter", "'name=^app-workers-latest$'", "--quiet", "|", :xargs, :docker, :inspect, "--format", Dash::Commands::Base::DOCKER_HEALTH_STATUS_FORMAT)
      .returns("unhealthy").at_least_once # workers health check

    run_command("boot", config: :with_roles, host: nil, allow_execute_error: true).tap do |output|
      assert_match "Waiting for the first healthy web container before booting workers on 1.1.1.3...", output
      assert_match "Waiting for the first healthy web container before booting workers on 1.1.1.4...", output
      assert_match "First web container is healthy, booting workers on 1.1.1.3", output
      assert_match "First web container is healthy, booting workers on 1.1.1.4", output
      assert_match "ERROR Failed to boot workers on 1.1.1.3", output
      assert_match "ERROR Failed to boot workers on 1.1.1.4", output
    end
  ensure
    Thread.report_on_exception = true
  end

  test "boot with worker ready then not" do
    Thread.report_on_exception = false

    Object.any_instance.stubs(:sleep)

    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("123") # container id
    stub_boot_state clash: "12345678", running: "123", expect: false

    SSHKit::Backend::Abstract.any_instance.expects(:capture_with_info)
      .with(:docker, :container, :ls, "--all", "--filter", "'name=^app-workers-latest$'", "--quiet", "|", :xargs, :docker, :inspect, "--format", Dash::Commands::Base::DOCKER_HEALTH_STATUS_FORMAT)
      .returns("no-healthcheck:running", "no-healthcheck:stopped").at_least_once # workers health check

    run_command("boot", config: :with_roles, host: "1.1.1.3", allow_execute_error: true).tap do |output|
      assert_match "ERROR Failed to boot workers on 1.1.1.3", output
    end
  ensure
    Thread.report_on_exception = true
  end

  test "boot failure on a non-primary role dumps container and health logs" do
    Thread.report_on_exception = false

    Object.any_instance.stubs(:sleep)

    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("123") # container id
    stub_boot_state clash: "12345678", running: "123", expect: false

    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with(:docker, :container, :ls, "--all", "--filter", "'name=^app-workers-latest$'", "--quiet", "|", :xargs, :docker, :inspect, "--format", Dash::Commands::Base::DOCKER_HEALTH_STATUS_FORMAT)
      .returns("unhealthy") # workers health check

    SSHKit::Backend::Abstract.any_instance.expects(:capture_with_info)
      .with(:docker, :container, :ls, "--all", "--filter", "'name=^app-workers-latest$'", "--quiet", "|", "xargs docker logs --timestamps 2>&1")
      .returns("Worker exited with status 1").at_least_once

    SSHKit::Backend::Abstract.any_instance.expects(:capture_with_info)
      .with(:docker, :container, :ls, "--all", "--filter", "'name=^app-workers-latest$'", "--quiet", "|", :xargs, :docker, :inspect, "--format", "'{{json .State.Health}}'")
      .returns('{"Status":"unhealthy","FailingStreak":3}').at_least_once

    run_command("boot", config: :with_roles, host: nil, allow_execute_error: true).tap do |output|
      assert_match "ERROR Failed to boot workers on 1.1.1.3", output
      assert_match "Worker exited with status 1", output
      assert_match "FailingStreak", output
      # The barrier belongs to web, so workers never reaches close_barrier
      assert_no_match "not booting any other roles", output
    end
  ensure
    Thread.report_on_exception = true
  end

  test "boot failure omits the health log when the container has no healthcheck" do
    Thread.report_on_exception = false

    Object.any_instance.stubs(:sleep)

    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("123") # container id
    stub_boot_state clash: "12345678", running: "123", expect: false

    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with(:docker, :container, :ls, "--all", "--filter", "'name=^app-workers-latest$'", "--quiet", "|", :xargs, :docker, :inspect, "--format", Dash::Commands::Base::DOCKER_HEALTH_STATUS_FORMAT)
      .returns("no-healthcheck:stopped") # workers has no healthcheck, container just died

    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with(:docker, :container, :ls, "--all", "--filter", "'name=^app-workers-latest$'", "--quiet", "|", "xargs docker logs --timestamps 2>&1")
      .returns("Worker exited with status 1")

    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with(:docker, :container, :ls, "--all", "--filter", "'name=^app-workers-latest$'", "--quiet", "|", :xargs, :docker, :inspect, "--format", "'{{json .State.Health}}'")
      .returns("null")

    run_command("boot", config: :with_roles, host: nil, allow_execute_error: true).tap do |output|
      assert_match "ERROR Failed to boot workers on 1.1.1.3", output
      assert_match "Worker exited with status 1", output
      assert_no_match /ERROR null/, output
    end
  ensure
    Thread.report_on_exception = true
  end

  test "boot with only workers" do
    Object.any_instance.stubs(:sleep)

    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("123") # container id
    stub_boot_state clash: "12345678", running: "123", expect: false

    SSHKit::Backend::Abstract.any_instance.expects(:capture_with_info)
      .with(:docker, :container, :ls, "--all", "--filter", "'name=^app-workers-latest$'", "--quiet", "|", :xargs, :docker, :inspect, "--format", Dash::Commands::Base::DOCKER_HEALTH_STATUS_FORMAT)
      .returns("no-healthcheck:running").at_least_once # workers health check

    run_command("boot", config: :with_only_workers, host: nil).tap do |output|
      assert_match /First workers container is healthy on 1.1.1.\d, booting any other roles/, output
      assert_no_match "dash-proxy", output
    end
  end

  test "boot with error pages" do
    with_error_pages(directory: "public") do
      stub_running
      run_command("boot", config: :with_error_pages).tap do |output|
        assert_match /Uploading .*kamal-error-pages.*\/latest to \.dash\/proxy\/apps-config\/app\/error_pages/, output
        assert_match "docker tag dhh/app:latest dhh/app:latest", output
        assert_match /docker run --detach --restart unless-stopped --name app-web-latest --network dash --hostname 1.1.1.1-[0-9a-f]{12} /, output
        assert_match "docker container ls --all --filter 'name=^app-web-123$' --quiet | xargs docker stop", output
        assert_match "Running /usr/bin/env find .dash/proxy/apps-config/app/error_pages -mindepth 1 -maxdepth 1 ! -name latest -exec rm -rf {} + on 1.1.1.1", output
      end
    end
  end

  test "boot with custom ssl certificate" do
    Dash::Configuration::Proxy.any_instance.stubs(:custom_ssl_certificate?).returns(true)
    Dash::Configuration::Proxy.any_instance.stubs(:certificate_pem_content).returns("CERTIFICATE CONTENT")
    Dash::Configuration::Proxy.any_instance.stubs(:private_key_pem_content).returns("PRIVATE KEY CONTENT")

    stub_running
    run_command("boot", config: :with_proxy).tap do |output|
      assert_match "Writing SSL certificates for web on 1.1.1.1", output
      assert_match "mkdir -p .dash/proxy/apps-config/app/tls", output
      assert_match "Uploading \"CERTIFICATE CONTENT\" to .dash/proxy/apps-config/app/tls/web/cert.pem", output
      assert_match "--tls-certificate-path=\"/home/dash-proxy/.apps-config/app/tls/web/cert.pem\"", output
      assert_match "--tls-private-key-path=\"/home/dash-proxy/.apps-config/app/tls/web/key.pem\"", output
    end
  end

  # The CA bundle is resolved from secrets on the machine running kamal and
  # written into the apps-config tree the proxy container already mounts, so
  # the flag can name a path that resolves inside the container.
  test "boot with an mTLS client CA" do
    Dash::Configuration::Proxy.any_instance.stubs(:client_ca?).returns(true)
    Dash::Configuration::Proxy.any_instance.stubs(:client_ca_pem_content).returns("ca-bundle-content")

    stub_running
    run_command("boot", config: :with_proxy).tap do |output|
      assert_match "Writing SSL certificates for web on 1.1.1.1", output
      assert_match "mkdir -p .dash/proxy/apps-config/app/tls", output
      assert_match "Uploading \"ca-bundle-content\" to .dash/proxy/apps-config/app/tls/web/client-ca.pem", output
      assert_match "--tls-client-ca-path=\"/home/dash-proxy/.apps-config/app/tls/web/client-ca.pem\"", output
    end
  end

  test "start" do
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("999") # old version

    run_command("start").tap do |output|
      assert_match "docker start app-web-999", output
      assert_match "docker exec dash-proxy dash-proxy deploy app-web --target=\"999:80\" --deploy-timeout=\"30s\" --drain-timeout=\"30s\" --buffer-requests --buffer-responses --log-request-header=\"Cache-Control\" --log-request-header=\"Last-Modified\"", output
    end
  end

  test "stop" do
    run_command("stop").tap do |output|
      assert_match "sh -c 'docker ps --latest --quiet --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting --filter ancestor=$(docker image ls --filter reference=dhh/app:latest --format '\\''{{.ID}}'\\'') ; docker ps --latest --quiet --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting' | head -1 | xargs docker stop", output
    end
  end

  test "stale_containers" do
    SSHKit::Backend::Abstract.any_instance.expects(:capture_with_info)
      .with(:docker, :ps, "--filter", "label=service=app", "--filter", "label=destination=", "--filter", "label=role=web", "--format", "\"{{.Names}}\"", "|", "while read line; do echo ${line#app-web-}; done", raise_on_non_zero_exit: false)
      .returns("12345678\n87654321\n")

    SSHKit::Backend::Abstract.any_instance.expects(:capture_with_info)
      .with(:sh, "-c", "'docker ps --latest --format '\\''{{.Names}}'\\'' --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting --filter ancestor=$(docker image ls --filter reference=dhh/app:latest --format '\\''{{.ID}}'\\'') ; docker ps --latest --format '\\''{{.Names}}'\\'' --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting'", "|", :head, "-1", "|", "while read line; do echo ${line#app-web-}; done", raise_on_non_zero_exit: false)
      .returns("12345678\n")

    run_command("stale_containers").tap do |output|
      assert_match /Detected stale container for role web with version 87654321/, output
    end
  end

  test "stop stale_containers" do
    SSHKit::Backend::Abstract.any_instance.expects(:capture_with_info)
      .with(:docker, :ps, "--filter", "label=service=app", "--filter", "label=destination=", "--filter", "label=role=web", "--format", "\"{{.Names}}\"", "|", "while read line; do echo ${line#app-web-}; done", raise_on_non_zero_exit: false)
      .returns("12345678\n87654321\n")

    SSHKit::Backend::Abstract.any_instance.expects(:capture_with_info)
      .with(:sh, "-c", "'docker ps --latest --format '\\''{{.Names}}'\\'' --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting --filter ancestor=$(docker image ls --filter reference=dhh/app:latest --format '\\''{{.ID}}'\\'') ; docker ps --latest --format '\\''{{.Names}}'\\'' --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting'", "|", :head, "-1", "|", "while read line; do echo ${line#app-web-}; done", raise_on_non_zero_exit: false)
      .returns("12345678\n")

    run_command("stale_containers", "--stop").tap do |output|
      assert_match /Stopping stale container for role web with version 87654321/, output
      assert_match /#{Regexp.escape("docker container ls --all --filter 'name=^app-web-87654321$' --quiet | xargs docker stop")}/, output
    end
  end

  test "details" do
    run_command("details").tap do |output|
      assert_match "docker ps --filter label=service=app --filter label=destination= --filter label=role=web", output
    end
  end

  test "remove" do
    run_command("remove").tap do |output|
      assert_match "sh -c 'docker ps --latest --quiet --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting --filter ancestor=$(docker image ls --filter reference=dhh/app:latest --format '\\''{{.ID}}'\\'') ; docker ps --latest --quiet --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting' | head -1 | xargs docker stop", output
      assert_match "docker container prune --force --filter label=service=app", output
      assert_match "docker image prune --all --force --filter label=service=app", output
      assert_match "rm -r .dash/apps/app on 1.1.1.1", output
      assert_match "rm -r .dash/proxy/apps-config/app on 1.1.1.1", output
    end
  end

  test "remove with role filter does not remove images or app directories" do
    run_command("remove", "-r", "workers", config: :with_two_roles_one_host).tap do |output|
      assert_match "docker stop", output
      assert_match "docker container prune --force --filter label=service=app", output
      # Images and directories should NOT be removed when other roles remain on the host
      assert_no_match(/docker image prune --all --force --filter label=service=app/, output)
      assert_no_match(/rm -r .dash\/apps\/app/, output)
      assert_no_match(/rm -r .dash\/proxy\/apps-config\/app/, output)
    end
  end

  test "remove with all roles on host removes images and app directories" do
    run_command("remove", "-r", "workers,web", config: :with_two_roles_one_host).tap do |output|
      assert_match "docker stop", output
      assert_match "docker container prune --force --filter label=service=app", output
      # Images and directories SHOULD be removed when all roles on host are removed
      assert_match "docker image prune --all --force --filter label=service=app", output
      assert_match "rm -r .dash/apps/app on 1.1.1.1", output
      assert_match "rm -r .dash/proxy/apps-config/app on 1.1.1.1", output
    end
  end

  test "remove_container" do
    run_command("remove_container", "1234567").tap do |output|
      assert_match "docker container ls --all --filter 'name=^app-web-1234567$' --quiet | xargs docker container rm", output
    end
  end

  test "remove_containers" do
    run_command("remove_containers").tap do |output|
      assert_match "docker container prune --force --filter label=service=app", output
    end
  end

  test "remove_images" do
    run_command("remove_images").tap do |output|
      assert_match "docker image prune --all --force --filter label=service=app", output
    end
  end

  test "remove_app_directories" do
    run_command("remove_app_directories").tap do |output|
      assert_match "rm -r .dash/apps/app on 1.1.1.1", output
      assert_match "rm -r .dash/proxy/apps-config/app on 1.1.1.1", output
    end
  end

  test "exec" do
    run_command("exec", "ruby -v").tap do |output|
      assert_match "docker login -u [REDACTED] -p [REDACTED]", output
      assert_match %r{docker run --rm --name app-web-exec-latest-[0-9a-f]{6} --network dash --env-file .dash/apps/app/env/roles/web.env --log-opt max-size="10m" dhh/app:latest ruby -v}, output
    end
  end

  test "exec without command fails" do
    error = assert_raises(ArgumentError, "Exec requires a command to be specified") do
      run_command("exec")
    end
    assert_equal "No command provided. You must specify a command to execute.", error.message
  end

  test "exec separate arguments" do
    run_command("exec", "ruby", " -v").tap do |output|
      assert_match %r{docker run --rm --name app-web-exec-latest-[0-9a-f]{6} --network dash --env-file .dash/apps/app/env/roles/web.env --log-opt max-size="10m" dhh/app:latest ruby -v}, output
    end
  end

  test "exec detach" do
    run_command("exec", "--detach", "ruby -v").tap do |output|
      assert_match %r{docker run --detach --name app-web-exec-latest-[0-9a-f]{6} --network dash --env-file .dash/apps/app/env/roles/web.env --log-opt max-size="10m" dhh/app:latest ruby -v}, output
    end
  end

  test "exec detach with reuse" do
    assert_raises(ArgumentError, "Detach is not compatible with reuse") do
      run_command("exec", "--detach", "--reuse", "ruby -v")
    end
  end

  test "exec detach with interactive" do
    assert_raises(ArgumentError, "Detach is not compatible with interactive") do
      run_command("exec", "--interactive", "--detach", "ruby -v")
    end
  end

  test "exec detach with interactive and reuse" do
    assert_raises(ArgumentError, "Detach is not compatible with interactive or reuse") do
      run_command("exec", "--interactive", "--detach", "--reuse", "ruby -v")
    end
  end

  test "exec with reuse" do
    run_command("exec", "--reuse", "ruby -v").tap do |output|
      assert_match "sh -c 'docker ps --latest --format '\\''{{.Names}}'\\'' --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting --filter ancestor=$(docker image ls --filter reference=dhh/app:latest --format '\\''{{.ID}}'\\'') ; docker ps --latest --format '\\''{{.Names}}'\\'' --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting' | head -1 | while read line; do echo ${line#app-web-}; done", output # Get current version
      assert_match "docker exec app-web-999 ruby -v", output
    end
  end

  test "exec interactive" do
    Dash::Commands::Hook.any_instance.stubs(:hook_exists?).returns(true)
    SSHKit::Backend::Abstract.any_instance.expects(:exec)
      .with(regexp_matches(%r{ssh -t root@1\.1\.1\.1 -p 22 'docker run -it --rm --name app-web-exec-latest-[0-9a-f]{6} --network dash --env-file .dash/apps/app/env/roles/web.env --log-opt max-size="10m" dhh/app:latest ruby -v'}))

    stub_stdin_tty do
      run_command("exec", "-i", "ruby -v").tap do |output|
        assert_hook_ran "pre-connect", output
        assert_match "docker login -u [REDACTED] -p [REDACTED]", output
        assert_match "Get most recent version available as an image...", output
        assert_match "Launching interactive command with version latest via SSH from new container on 1.1.1.1...", output
      end
    end
  end

  test "exec interactive with reuse" do
    Dash::Commands::Hook.any_instance.stubs(:hook_exists?).returns(true)
    SSHKit::Backend::Abstract.any_instance.expects(:exec)
      .with("ssh -t root@1.1.1.1 -p 22 'docker exec -it app-web-999 ruby -v'")

    stub_stdin_tty do
      run_command("exec", "-i", "--reuse", "ruby -v").tap do |output|
        assert_hook_ran "pre-connect", output
        assert_match "Get current version of running container...", output
        assert_match "Running /usr/bin/env sh -c 'docker ps --latest --format '\\''{{.Names}}'\\'' --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting --filter ancestor=$(docker image ls --filter reference=dhh/app:latest --format '\\''{{.ID}}'\\'') ; docker ps --latest --format '\\''{{.Names}}'\\'' --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting' | head -1 | while read line; do echo ${line#app-web-}; done on 1.1.1.1", output
        assert_match "Launching interactive command with version 999 via SSH from existing container on 1.1.1.1...", output
      end
    end
  end

  test "exec interactive with pipe on STDIN" do
    Dash::Commands::Hook.any_instance.stubs(:hook_exists?).returns(true)
    SSHKit::Backend::Abstract.any_instance.expects(:exec)
      .with("ssh -t root@1.1.1.1 -p 22 'docker exec -i app-web-999 ruby -v'")

    stub_stdin_file do
      run_command("exec", "-i", "--reuse", "ruby -v").tap do |output|
        assert_hook_ran "pre-connect", output
        assert_match "Launching interactive command with version 999 via SSH from existing container on 1.1.1.1...", output
      end
    end
  end

  test "containers" do
    run_command("containers").tap do |output|
      assert_match "docker container ls --all --filter label=service=app", output
    end
  end

  test "images" do
    run_command("images").tap do |output|
      assert_match "docker image ls dhh/app", output
    end
  end

  test "logs" do
    SSHKit::Backend::Abstract.any_instance.stubs(:exec)
      .with("ssh -t root@1.1.1.1 'sh -c 'docker ps --latest --quiet --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting --filter ancestor=$(docker image ls --filter reference=dhh/app:latest --format '\\''{{.ID}}'\\'') ; docker ps --latest --quiet --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting' | head -1| xargs docker logs --timestamps --tail 10 2>&1'")

    assert_match "sh -c 'docker ps --latest --quiet --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting --filter ancestor=$(docker image ls --filter reference=dhh/app:latest --format '\\''{{.ID}}'\\'') ; docker ps --latest --quiet --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting' | head -1 | xargs docker logs --timestamps --tail 100 2>&1", run_command("logs")

    assert_match "sh -c 'docker ps --latest --quiet --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting --filter ancestor=$(docker image ls --filter reference=dhh/app:latest --format '\\''{{.ID}}'\\'') ; docker ps --latest --quiet --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting' | head -1 | xargs docker logs --timestamps 2>&1 | grep 'hey'", run_command("logs", "--grep", "hey")

    assert_match "sh -c 'docker ps --latest --quiet --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting --filter ancestor=$(docker image ls --filter reference=dhh/app:latest --format '\\''{{.ID}}'\\'') ; docker ps --latest --quiet --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting' | head -1 | xargs docker logs --timestamps 2>&1 | grep 'hey' -C 2", run_command("logs", "--grep", "hey", "--grep-options", "-C 2")
  end

  test "logs with follow" do
    SSHKit::Backend::Abstract.any_instance.stubs(:exec)
      .with("ssh -t root@1.1.1.1 -p 22 'sh -c '\\''docker ps --latest --quiet --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting --filter ancestor=$(docker image ls --filter reference=dhh/app:latest --format '\\''\\'\\'''\\''{{.ID}}'\\''\\'\\'''\\'') ; docker ps --latest --quiet --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting'\\'' | head -1 | xargs docker logs --timestamps --tail 10 --follow 2>&1'")

    assert_match "sh -c '\\''docker ps --latest --quiet --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting --filter ancestor=$(docker image ls --filter reference=dhh/app:latest --format '\\''\\'\\'''\\''{{.ID}}'\\''\\'\\'''\\'') ; docker ps --latest --quiet --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting'\\'' | head -1 | xargs docker logs --timestamps --tail 10 --follow 2>&1", run_command("logs", "--follow")
  end

  test "logs with follow and container_id" do
    SSHKit::Backend::Abstract.any_instance.stubs(:exec)
      .with("ssh -t root@1.1.1.1 -p 22 'sh -c '\\''echo ID123'\\'' | xargs docker logs --timestamps --tail 10 --follow 2>&1'")

    assert_match "sh -c '\\''echo ID123'\\'' | xargs docker logs --timestamps --tail 10 --follow 2>&1", run_command("logs", "--follow", "--container-id", "ID123")
  end

  test "logs with follow and grep" do
    SSHKit::Backend::Abstract.any_instance.stubs(:exec)
      .with("ssh -t root@1.1.1.1 -p 22 'sh -c '\\''docker ps --latest --quiet --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting --filter ancestor=$(docker image ls --filter reference=dhh/app:latest --format '\\''\\'\\'''\\''{{.ID}}'\\''\\'\\'''\\'') ; docker ps --latest --quiet --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting'\\'' | head -1 | xargs docker logs --timestamps --follow 2>&1 | grep \"hey\"'")

    assert_match "sh -c '\\''docker ps --latest --quiet --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting --filter ancestor=$(docker image ls --filter reference=dhh/app:latest --format '\\''\\'\\'''\\''{{.ID}}'\\''\\'\\'''\\'') ; docker ps --latest --quiet --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting'\\'' | head -1 | xargs docker logs --timestamps --follow 2>&1 | grep \"hey\"", run_command("logs", "--follow", "--grep", "hey")
  end

  test "logs with follow, grep and grep options" do
    SSHKit::Backend::Abstract.any_instance.stubs(:exec)
      .with("ssh -t root@1.1.1.1 -p 22 'sh -c '\\''docker ps --latest --quiet --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting --filter ancestor=$(docker image ls --filter reference=dhh/app:latest --format '\\''\\'\\'''\\''{{.ID}}'\\''\\'\\'''\\'') ; docker ps --latest --quiet --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting'\\'' | head -1 | xargs docker logs --timestamps --follow 2>&1 | grep \"hey\" -C 2'")

    assert_match "sh -c '\\''docker ps --latest --quiet --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting --filter ancestor=$(docker image ls --filter reference=dhh/app:latest --format '\\''\\'\\'''\\''{{.ID}}'\\''\\'\\'''\\'') ; docker ps --latest --quiet --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting'\\'' | head -1 | xargs docker logs --timestamps --follow 2>&1 | grep \"hey\" -C 2", run_command("logs", "--follow", "--grep", "hey", "--grep-options", "-C 2")
  end

  test "version" do
    run_command("version").tap do |output|
      assert_match "sh -c 'docker ps --latest --format '\\''{{.Names}}'\\'' --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting --filter ancestor=$(docker image ls --filter reference=dhh/app:latest --format '\\''{{.ID}}'\\'') ; docker ps --latest --format '\\''{{.Names}}'\\'' --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting' | head -1 | while read line; do echo ${line#app-web-}; done", output
    end
  end


  test "version through main" do
    with_argv([ "app", "version", "-c", "test/fixtures/deploy_with_accessories.yml", "--hosts", "1.1.1.1" ]) do
      stdouted { Dash::Cli::Main.start }.tap do |output|
        assert_match "sh -c 'docker ps --latest --format '\\''{{.Names}}'\\'' --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting --filter ancestor=$(docker image ls --filter reference=dhh/app:latest --format '\\''{{.ID}}'\\'') ; docker ps --latest --format '\\''{{.Names}}'\\'' --filter label=service=app --filter label=destination= --filter label=role=web --filter status=running --filter status=restarting' | head -1 | while read line; do echo ${line#app-web-}; done", output
      end
    end
  end

  test "long hostname" do
    stub_running

    hostname = "this-hostname-is-really-unacceptably-long-to-be-honest.example.com"

    stdouted { Dash::Cli::App.start([ "boot", "-c", "test/fixtures/deploy_with_uncommon_hostnames.yml", "--hosts", hostname ]) }.tap do |output|
      assert_match /docker run --detach --restart unless-stopped --name app-web-latest --network dash --hostname this-hostname-is-really-unacceptably-long-to-be-hon-[0-9a-f]{12} /, output
    end
  end

  test "hostname is trimmed if will end with a period" do
    stub_running

    hostname = "this-hostname-with-random-part-is-too-long.example.com"

    stdouted { Dash::Cli::App.start([ "boot", "-c", "test/fixtures/deploy_with_uncommon_hostnames.yml", "--hosts", hostname ]) }.tap do |output|
      assert_match /docker run --detach --restart unless-stopped --name app-web-latest --network dash --hostname this-hostname-with-random-part-is-too-long.example-[0-9a-f]{12} /, output
    end
  end

  test "boot proxy" do
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("123") # container id
    stub_boot_state clash: "12345678", running: "123", expect: false

    run_command("boot", config: :with_proxy).tap do |output|
      assert_match /Renaming container .* to .* as already deployed on 1.1.1.1/, output # Rename
      assert_match /docker rename app-web-latest app-web-latest_replaced_[0-9a-f]{16}/, output
      assert_match /docker run --detach --restart unless-stopped --name app-web-latest --network dash --hostname 1.1.1.1-[0-9a-f]{12} --env KAMAL_CONTAINER_NAME="app-web-latest" --env KAMAL_VERSION="latest" --env KAMAL_HOST="1.1.1.1" --env-file .dash\/apps\/app\/env\/roles\/web.env --log-opt max-size="10m" --label service="app" --label role="web" --label destination dhh\/app:latest/, output
      assert_match /Deploying web on 1.1.1.1 via dash-proxy \(waiting up to 6s for it to become healthy\).../, output
      assert_match /docker exec dash-proxy dash-proxy deploy app-web --target="123:80"/, output
      assert_match "docker container ls --all --filter 'name=^app-web-123$' --quiet | xargs docker stop", output
    end
  end

  test "boot proxy with role specific config" do
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("123") # container id
    stub_boot_state clash: "12345678", running: "123", expect: false

    run_command("boot", config: :with_proxy_roles, host: nil).tap do |output|
      assert_match "docker exec dash-proxy dash-proxy deploy app-web --target=\"123:80\" --deploy-timeout=\"6s\" --drain-timeout=\"30s\" --target-timeout=\"10s\" --buffer-requests --buffer-responses --log-request-header=\"Cache-Control\" --log-request-header=\"Last-Modified\" --log-request-header=\"User-Agent\"", output
      assert_match "docker exec dash-proxy dash-proxy deploy app-web2 --target=\"123:80\" --deploy-timeout=\"6s\" --drain-timeout=\"30s\" --target-timeout=\"15s\" --buffer-requests --buffer-responses --log-request-header=\"Cache-Control\" --log-request-header=\"Last-Modified\" --log-request-header=\"User-Agent\"", output
    end
  end

  test "boot runs proxy deploy hooks around the proxy deploy" do
    Dash::Commands::Hook.any_instance.stubs(:hook_exists?).returns(true)
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("123") # container id
    stub_boot_state clash: "12345678", running: "123", expect: false

    run_command("boot", config: :with_proxy).tap do |output|
      assert_hook_ran "pre-proxy-deploy", output
      assert_hook_ran "post-proxy-deploy", output
      assert_match /pre-proxy-deploy.*dash-proxy deploy app-web.*post-proxy-deploy/m, output
    end
  end

  test "boot passes the host and role to the proxy deploy hooks" do
    Dash::Cli::App.any_instance.stubs(:run_hook)
    Dash::Cli::App.any_instance.expects(:run_hook).with("pre-proxy-deploy", hosts: "1.1.1.1", role: "web")
    Dash::Cli::App.any_instance.expects(:run_hook).with("post-proxy-deploy", hosts: "1.1.1.1", role: "web")

    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("123") # container id
    stub_boot_state clash: "12345678", running: "123", expect: false

    run_command("boot", config: :with_proxy)
  end

  test "boot skips proxy deploy hooks for roles not running the proxy" do
    Dash::Commands::Hook.any_instance.stubs(:hook_exists?).returns(true)
    Dash::Cli::Healthcheck::Poller.stubs(:wait_for_healthy)
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("123") # container id
    stub_boot_state clash: "12345678", running: "123", expect: false

    run_command("boot", config: :with_proxy, host: "1.1.1.3").tap do |output|
      assert_hook_ran "pre-app-boot", output
      assert_no_match /hooks\/pre-proxy-deploy/, output
      assert_no_match /hooks\/post-proxy-deploy/, output
    end
  end

  test "boot skips proxy deploy hooks with --skip-hooks" do
    Dash::Commands::Hook.any_instance.stubs(:hook_exists?).returns(true)
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("123") # container id
    stub_boot_state clash: "12345678", running: "123", expect: false

    run_command("boot", "--skip-hooks", config: :with_proxy).tap do |output|
      assert_match /dash-proxy deploy app-web/, output
      assert_no_match /hooks\/pre-proxy-deploy/, output
      assert_no_match /hooks\/post-proxy-deploy/, output
    end
  end

  test "boot aborts when the pre-proxy-deploy hook fails" do
    fail_hook("pre-proxy-deploy")
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("123") # container id
    stub_boot_state clash: "12345678", running: "123", expect: false

    stderred { run_command("boot", config: :with_proxy, allow_execute_error: true) }

    assert @executions.none? { |args| args.join(" ").include?("dash-proxy deploy") }
    assert @executions.any? { |args| args.join(" ").include?("app-web-latest") && args.join(" ").include?("docker stop") }
  end

  test "boot runs app stop hooks around stopping the old version" do
    Dash::Commands::Hook.any_instance.stubs(:hook_exists?).returns(true)
    stub_running

    run_command("boot").tap do |output|
      assert_hook_ran "pre-app-stop", output
      assert_hook_ran "post-app-stop", output
      assert_match /pre-app-stop.*app-web-123.*xargs docker stop.*post-app-stop/m, output
    end
  end

  test "boot passes the host, role and stopped version to the app stop hooks" do
    Dash::Cli::App.any_instance.stubs(:run_hook)
    Dash::Cli::App.any_instance.expects(:run_hook).with("pre-app-stop", hosts: "1.1.1.1", role: "web", version: "123")
    Dash::Cli::App.any_instance.expects(:run_hook).with("post-app-stop", hosts: "1.1.1.1", role: "web", version: "123")

    stub_running

    run_command("boot")
  end

  test "boot runs app stop hooks for a non-proxied role" do
    Dash::Commands::Hook.any_instance.stubs(:hook_exists?).returns(true)
    Dash::Cli::Healthcheck::Poller.stubs(:wait_for_healthy)
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("123") # container id
    stub_boot_state clash: "12345678", running: "123", expect: false

    run_command("boot", config: :with_proxy, host: "1.1.1.3").tap do |output|
      assert_no_match /hooks\/pre-proxy-deploy/, output
      assert_match /pre-app-stop.*app-workers-123.*xargs docker stop.*post-app-stop/m, output
    end
  end

  test "boot runs app stop hooks for proxied roles too" do
    Dash::Commands::Hook.any_instance.stubs(:hook_exists?).returns(true)
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("123") # container id
    stub_boot_state clash: "12345678", running: "123", expect: false

    run_command("boot", config: :with_proxy).tap do |output|
      assert_match /dash-proxy deploy app-web.*pre-app-stop/m, output
    end
  end

  test "boot doesn't run app stop hooks when there is no old version" do
    Dash::Commands::Hook.any_instance.stubs(:hook_exists?).returns(true)
    Object.any_instance.stubs(:sleep)
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("12345678")
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with { |*args| args.first == :sh }.returns("") # no old version running

    run_command("boot").tap do |output|
      assert_no_match /hooks\/pre-app-stop/, output
      assert_no_match /hooks\/post-app-stop/, output
    end
  end

  test "boot skips app stop hooks with --skip-hooks" do
    Dash::Commands::Hook.any_instance.stubs(:hook_exists?).returns(true)
    stub_running

    run_command("boot", "--skip-hooks").tap do |output|
      assert_match "docker container ls --all --filter 'name=^app-web-123$' --quiet | xargs docker stop", output
      assert_no_match /hooks\/pre-app-stop/, output
      assert_no_match /hooks\/post-app-stop/, output
    end
  end

  test "boot continues the deploy when the pre-app-stop hook fails" do
    fail_hook("pre-app-stop")
    Object.any_instance.stubs(:sleep)
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("123") # container id
    stub_boot_state clash: "12345678", running: "123", expect: false

    stderred { run_command("boot") }

    assert @executions.any? { |args| args.join(" ").include?("app-web-123") && args.join(" ").include?("docker stop") }
    assert @executions.any? { |args| args.first == ".dash/hooks/post-app-stop" }
  end

  test "boot gates a role with an exec healthcheck on the probe's exit code" do
    stub_running

    run_command("boot", config: :with_readiness_sources, host: "1.1.1.8").tap do |output|
      assert_match "docker exec app-prober-latest sh -c 'bin/ready-check'", output
      assert_match /Container is healthy!/, output
      assert_no_match %r{--health-cmd}, output
    end
  end

  test "boot leaves the old container running when the exec probe never passes" do
    Dash::Configuration.any_instance.stubs(:deploy_timeout).returns(0)
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("123") # container id
    stub_boot_state clash: "12345678", running: "123", expect: false

    @executions = []
    SSHKit::Backend::Abstract.any_instance.stubs(:execute)
      .with { |*args| @executions << args; !args.join(" ").include?("bin/ready-check") }
    SSHKit::Backend::Abstract.any_instance.stubs(:execute)
      .with { |*args| args.join(" ").include?("bin/ready-check") }
      .raises(SSHKit::Command::Failed.new("probe failed"))

    stderred { run_command("boot", config: :with_readiness_sources, host: "1.1.1.8", allow_execute_error: true) }

    assert @executions.any? { |args| args.join(" ").include?("sh -c 'bin/ready-check'") }, "expected the probe to have run"
    assert @executions.any? { |args| args.join(" ").include?("docker run") }, "expected the new container to have booted"
    assert @executions.none? { |args| args.join(" ").include?("app-prober-123") }, "expected the old container to be left alone"
  end

  test "start runs proxy deploy hooks around the proxy deploy" do
    Dash::Commands::Hook.any_instance.stubs(:hook_exists?).returns(true)
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("999") # old version

    run_command("start").tap do |output|
      assert_match /pre-proxy-deploy.*dash-proxy deploy app-web.*post-proxy-deploy/m, output
    end
  end

  test "live" do
    run_command("live").tap do |output|
      assert_match "docker exec dash-proxy dash-proxy resume app-web on 1.1.1.1", output
    end
  end

  test "maintenance" do
    run_command("maintenance").tap do |output|
      assert_match "docker exec dash-proxy dash-proxy stop app-web --drain-timeout=\"30s\" on 1.1.1.1", output
    end
  end

  test "maintenance with options" do
    run_command("maintenance", "--message", "Hello", "--drain_timeout", "10").tap do |output|
      assert_match "docker exec dash-proxy dash-proxy stop app-web --drain-timeout=\"10s\" --message=\"Hello\" on 1.1.1.1", output
    end
  end

  test "rollout deploy" do
    Object.any_instance.stubs(:sleep)
    stub_rollout_target_not_deployed

    run_command("rollout", "deploy").tap do |output|
      assert_match /docker run --detach --restart unless-stopped --name app-web-latest --network dash --hostname 1.1.1.1-[0-9a-f]{12} /, output
      assert_match "docker exec dash-proxy dash-proxy rollout deploy app-web --target=\"12345678:80\" --deploy-timeout=\"30s\" --drain-timeout=\"30s\"", output
    end
  end

  test "rollout deploy leaves the live version running" do
    Object.any_instance.stubs(:sleep)
    stub_rollout_target_not_deployed

    run_command("rollout", "deploy").tap do |output|
      assert_no_match /dash-proxy deploy app-web/, output
      assert_no_match /xargs docker stop/, output
    end
  end

  test "rollout deploy fails when the version is already deployed" do
    Object.any_instance.stubs(:sleep)
    SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
      .with(:docker, :container, :ls, "--all", "--filter", "'name=^app-web-latest$'", "--quiet", raise_on_non_zero_exit: false)
      .returns("12345678")

    run_command("rollout", "deploy", allow_execute_error: true).tap do |output|
      assert_match /Version latest is already deployed/, output
      assert_no_match /dash-proxy rollout deploy/, output
    end
  end

  test "rollout set with percent" do
    run_command("rollout", "set", "--percent", "10").tap do |output|
      assert_match "docker exec dash-proxy dash-proxy rollout set app-web --percent=\"10\" on 1.1.1.1", output
    end
  end

  test "rollout set with list" do
    run_command("rollout", "set", "--list", "dhh", "jorge").tap do |output|
      assert_match "docker exec dash-proxy dash-proxy rollout set app-web --list=\"dhh\" --list=\"jorge\" on 1.1.1.1", output
    end
  end

  test "rollout set with percent zero parks the rollout without tearing it down" do
    run_command("rollout", "set", "--percent", "0").tap do |output|
      assert_match "docker exec dash-proxy dash-proxy rollout set app-web --percent=\"0\" on 1.1.1.1", output
    end
  end

  test "rollout set without percent or list" do
    assert_raises(ArgumentError) { run_command("rollout", "set") }
  end

  test "rollout stop" do
    run_command("rollout", "stop").tap do |output|
      assert_match "docker exec dash-proxy dash-proxy rollout stop app-web on 1.1.1.1", output
    end
  end

  test "rollout with an unknown action" do
    assert_raises(ArgumentError) { run_command("rollout", "frobnicate") }
  end

  private
    def stub_rollout_target_not_deployed
      SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
        .with(:docker, :container, :ls, "--all", "--filter", "'name=^app-web-latest$'", "--quiet", raise_on_non_zero_exit: false)
        .returns("")
      SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
        .with(:docker, :container, :ls, "--all", "--filter", "'name=^app-web-latest$'", "--quiet")
        .returns("12345678")
    end

    def run_command(*command, config: :with_accessories, host: "1.1.1.1", allow_execute_error: false)
      stdouted do
        Dash::Cli::App.start([ *command, "-c", "test/fixtures/deploy_#{config}.yml", *([ "--hosts", host ] if host) ])
      rescue SSHKit::Runner::ExecuteError => e
        raise e unless allow_execute_error
      end
    end

    def stub_running
      Object.any_instance.stubs(:sleep)

      SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).returns("123") # container id
      stub_boot_state clash: nil, running: "123", expect: false
    end

    # The one capture Dash::Cli::App::Boot makes before it starts anything: the id of a
    # container already holding this version, then the version running now.
    def stub_boot_state(clash:, running:, expect: true)
      backend = SSHKit::Backend::Abstract.any_instance
      matcher = ->(*args) { args.join(" ").include?(Dash::Commands::App::BOOT_STATE_SEPARATOR) }

      (expect ? backend.expects(:capture_with_info) : backend.stubs(:capture_with_info))
        .with(&matcher)
        .returns("#{clash}\n#{Dash::Commands::App::BOOT_STATE_SEPARATOR}\n#{running}")
    end
end
