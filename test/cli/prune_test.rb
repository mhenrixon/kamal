require_relative "cli_test_case"

class CliPruneTest < CliTestCase
  test "all" do
    Dash::Cli::Prune.any_instance.expects(:containers)
    Dash::Cli::Prune.any_instance.expects(:images)

    run_command("all")
  end

  test "images" do
    run_command("images").tap do |output|
      assert_match "docker image prune --force --filter label=service=app && docker image ls", output
      assert_match "docker image ls --filter label=service=app --format '{{.ID}} {{.Repository}}:{{.Tag}}' | grep -v -w \"$(docker container ls -a --format '{{.Image}}\\|' --filter label=service=app | tr -d '\\n')dhh/app:latest\\|dhh/app:<none>\" | while read image tag; do docker rmi $tag; done on 1.1.1.", output
    end
  end

  test "containers" do
    run_command("containers").tap do |output|
      assert_match /docker ps -q -a --filter label=service=app --filter label=destination= --filter label=role=web --filter status=created --filter status=exited --filter status=dead | tail -n \+6 | while read container_id; do docker rm \$container_id; done on 1.1.1.\d/, output
     end

    run_command("containers", "--retain", "10").tap do |output|
      assert_match /docker ps -q -a --filter label=service=app --filter label=destination= --filter label=role=web --filter status=created --filter status=exited --filter status=dead | tail -n \+11 | while read container_id; do docker rm \$container_id; done on 1.1.1.\d/, output
    end

    assert_raises(RuntimeError, "retain must be at least 1") do
      run_command("containers", "--retain", "0")
    end
  end

  test "containers prunes every role on the host separately" do
    run_command("containers", config_file: "test/fixtures/deploy_with_roles.yml").tap do |output|
      assert_match "--filter label=role=web --filter status=created", output
      assert_match "--filter label=role=workers --filter status=created", output
    end
  end

  # A prune sweep is an audit line plus one docker command per thing being pruned. They
  # ran as separate round trips; now the audit leads the same shell string.
  test "images prunes in one round trip per host" do
    commands = recorded_commands { run_command("images") }

    prunes = commands.select { |command| command.include?("docker image prune") }
    assert_equal DASH.hosts.size, prunes.size
    assert prunes.all? { |command| command.include?("Pruned images") && command.include?("docker image ls") }, prunes.inspect
  end

  test "containers prunes a host's roles in one round trip" do
    commands = recorded_commands { run_command("containers", config_file: "test/fixtures/deploy_with_roles.yml") }

    prunes = commands.select { |command| command.include?("Pruned containers") }
    assert_equal DASH.hosts.size, prunes.size
    assert prunes.any? { |command| command.include?("label=role=web --filter status=created") }, prunes.inspect
    assert prunes.any? { |command| command.include?("label=role=workers --filter status=created") }, prunes.inspect
  end

  # The run directory is swept once per host per process. `prune all` takes the deploy
  # lock and then the server lock, and the second acquire used to re-sweep every host.
  test "the run directory is ensured once per host across both locks" do
    Dash::Cli::Prune.any_instance.stubs(:containers)
    Dash::Cli::Prune.any_instance.stubs(:images)

    commands = recorded_commands { run_command("all") }

    sweeps = commands.select { |command| command == "test -d .kamal && test ! -e .dash && mv .kamal .dash || true && mkdir -p .dash" }
    assert_equal DASH.hosts.size, sweeps.size
  end

  private
    def run_command(*command, config_file: "test/fixtures/deploy_with_accessories.yml")
      stdouted { Dash::Cli::Prune.start([ *command, "-c", config_file ]) }
    end
end
