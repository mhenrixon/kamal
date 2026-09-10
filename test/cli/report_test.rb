require_relative "cli_test_case"

class CliReportTest < CliTestCase
  test "with nothing saved it says so rather than printing an empty table" do
    assert_match "No saved reports for app in #{@reports_directory}", run_command("show")
  end

  # `dash report` with no subcommand is the way this is used; `dash report show` is the
  # long form Thor needs to have something to dispatch to.
  test "bare dash report prints the latest saved report" do
    save "2026-09-10T12-00-00Z-default-deploy.json"

    assert_match "Deploy report for app", run_command
  end

  test "prints the latest report the way the deploy printed it" do
    save "2026-09-10T12-00-00Z-default-deploy.json", runtime: 100.0
    save "2026-09-11T12-00-00Z-default-deploy.json", runtime: 196.2

    run_command("show").tap do |output|
      assert_match "Deploy report for app", output
      assert_match "deploy succeeded in 196.2s at 2026-09-11T12:00:00Z (version abc1234)", output
      assert_match(/\n  Build and push app image\s+140\.0s\n    \[build 1\/5\] RUN bundle install\s+84\.1s\n/, output)
      assert_match(/\n  Advice\n    warn  Dockerfile:14\s+COPY \. \. busts the install\n/, output)
      assert_match(/\n\s+→ copy the manifests first\z/, output)
    end
  end

  test "the build rows come back under the phase they were measured in" do
    save "2026-09-10T12-00-00Z-default-deploy.json"

    lines = run_command("show").lines.map(&:rstrip)
    build = lines.index { |line| line.start_with?("  Build and push app image") }

    assert_match "[build 1/5] RUN bundle install", lines[build + 1]
    assert_equal "→ copy the manifests first", lines.last.strip
  end

  test "a failed report names what ended it" do
    save "2026-09-10T12-00-00Z-default-deploy.json", status: "failed", error: { class: "RuntimeError", message: "boom" }

    assert_match "deploy failed in 196.2s", run_command("show")
    assert_match "— RuntimeError: boom", run_command("show")
  end

  test "--last prints one row per report, oldest first" do
    save "2026-09-10T12-00-00Z-default-deploy.json", runtime: 100.0
    save "2026-09-11T12-00-00Z-default-deploy.json", runtime: 196.2

    run_command("--last", "5").tap do |output|
      assert_match "Last 2 reports for app", output
      assert_match(/started\s+version\s+total\s+build\s+boot\s+advice/, output)
      assert_match(/2026-09-10T12:00:00Z\s+abc1234\s+100\.0s\s+140\.0s\s+55\.2s\s+1 \(1 warn\)/, output)
      assert_operator output.index("2026-09-10T12:00:00Z"), :<, output.index("2026-09-11T12:00:00Z")
    end
  end

  test "--last takes at most the number asked for" do
    3.times { |i| save "2026-09-1#{i}T12-00-00Z-default-deploy.json" }

    assert_match "Last 2 reports for app", run_command("--last", "2")
  end

  test "a phase a report never had prints a dash rather than a zero" do
    save "2026-09-10T12-00-00Z-default-deploy.json", phases: [ { name: "Boot", depth: 0, seconds: 5.0 } ]

    assert_match(/2026-09-10T12:00:00Z\s+abc1234\s+196\.2s\s+-\s+5\.0s/, run_command("--last", "5"))
  end

  test "path prints where reports are written" do
    assert_equal @reports_directory, run_command("path")
  end

  test "a destination reads the reports it saved" do
    save "2026-09-10T12-00-00Z-world-deploy.json", destination: "world"

    assert_match "Deploy report for app to world", run_command("show", config_file: "deploy_for_dest", destination: "world")
  end

  test "another destination's reports are not this one's history" do
    save "2026-09-10T12-00-00Z-world-deploy.json", destination: "world"

    assert_match "No saved reports for app in", run_command("show")
  end

  # Reading a report is a local operation: nothing here may open an SSH connection or
  # take a lock, so it stays usable while a deploy is running.
  test "reading a report issues no commands at all" do
    save "2026-09-10T12-00-00Z-default-deploy.json"
    commands = []
    SSHKit::Backend::Printer.any_instance.stubs(:execute_command).with { |cmd| commands << cmd.to_command; true }

    run_command("show")
    run_command("--last", "5")

    assert_empty commands
  end

  private
    def run_command(*command, config_file: "deploy_simple", destination: nil)
      argv = [ "report", *command, "-c", "test/fixtures/#{config_file}.yml" ]
      argv += [ "-d", destination ] if destination

      with_argv(argv) { stdouted { Dash::Cli::Main.start } }
    end

    def save(name, destination: nil, runtime: 196.2, status: "succeeded", error: nil, phases: nil)
      FileUtils.mkdir_p @reports_directory
      File.write File.join(@reports_directory, name),
        JSON.pretty_generate(document(started_at_in(name), destination, runtime, status, error, phases))
    end

    # The writer names a file after the timestamp inside it, with the colons a filename
    # cannot have; these fixtures are built the same way round.
    def started_at_in(name)
      stamp = name[0, 20]

      stamp[0, 11] + stamp[11..].tr("-", ":")
    end

    def document(started_at, destination, runtime, status, error, phases)
      {
        schema: Dash::Report::SCHEMA, dash_version: Dash::VERSION, command: "deploy", service: "app",
        destination: destination, version: "abc1234",
        started_at: started_at, runtime: runtime, status: status, error: error,
        phases: phases || default_phases, build_phase: (1 unless phases), build: (build unless phases),
        advice: advice
      }.compact
    end

    def default_phases
      [ { name: "Startup (load, config)", depth: 0, seconds: 1.0, commands: 0, command_seconds: 0.0, connect_seconds: 0.0, local: true },
        { name: "Build and push app image", depth: 0, seconds: 140.0, commands: 0, command_seconds: 0.0, connect_seconds: 0.0, local: true },
        { name: "Boot", depth: 0, seconds: 55.2, commands: 12, command_seconds: 41.0, connect_seconds: 1.2, local: false } ]
    end

    def build
      { push_seconds: 12.0, steps: [
        { number: 1, kind: "instruction", label: "[build 1/5] RUN bundle install", stage: "build", ordinal: 1,
          steps_in_stage: 5, instruction: "RUN bundle install", seconds: 84.1, cached: false } ] }
    end

    def advice
      [ { rule: "copy-before-install", severity: "warn", location: "Dockerfile:14",
          message: "COPY . . busts the install", suggestion: "copy the manifests first" } ]
    end
end
