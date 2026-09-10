require "test_helper"

class OutputOtelLoggerTest < ActiveSupport::TestCase
  setup do
    @tags = Dash::Tags.new(
      performer: "deployer",
      service: "myapp",
      version: "abc123",
      destination: "production"
    )
    Dash::OtelShipper.any_instance.stubs(:start_flush_thread)
    Dash::OtelShipper.any_instance.stubs(:flush)
    @logger = Dash::Output::OtelLogger.new(endpoint: "http://localhost:4318", tags: @tags, service: "myapp")
    @original_stdout, $stdout = $stdout, StringIO.new
  end

  teardown do
    @logger.close
    $stdout = @original_stdout
  end

  test "start event includes subcommand in command" do
    Dash::OtelShipper.any_instance.expects(:event).with("kamal.start", "kamal.command": "app boot")
    @logger.start("modify.kamal", "id", command: "app", subcommand: "boot", hosts: [ "1.1.1.1" ])
  end

  test "start event uses just command when no subcommand" do
    Dash::OtelShipper.any_instance.expects(:event).with("kamal.start",
      "kamal.command": "deploy",
      "deployment.id": anything, "deployment.name": "deploy myapp")
    @logger.start("modify.kamal", "id", command: "deploy", subcommand: nil, hosts: [ "1.1.1.1" ])
  end

  test "deploy complete event includes deployment status" do
    @logger.start("modify.kamal", "id", command: "deploy", hosts: [ "1.1.1.1" ])
    Dash::OtelShipper.any_instance.expects(:event).with("kamal.complete",
      "kamal.command": "deploy", "kamal.runtime": anything,
      "deployment.id": anything, "deployment.name": "deploy myapp", "deployment.status": "succeeded")
    @logger.finish("modify.kamal", "id", command: "deploy")
  end

  test "deploy failed event includes deployment status" do
    @logger.start("modify.kamal", "id", command: "deploy", hosts: [ "1.1.1.1" ])
    Dash::OtelShipper.any_instance.expects(:event).with("kamal.failed",
      severity: :error, "kamal.command": "deploy", "kamal.runtime": anything,
      "exception.type": "RuntimeError", "exception.message": "boom",
      "deployment.id": anything, "deployment.name": "deploy myapp", "deployment.status": "failed")
    @logger.finish("modify.kamal", "id", command: "deploy", exception: [ "RuntimeError", "boom" ])
  end

  test "non-deploy commands omit deployment attributes" do
    Dash::OtelShipper.any_instance.expects(:event).with("kamal.start", "kamal.command": "app boot")
    @logger.start("modify.kamal", "id", command: "app", subcommand: "boot", hosts: [ "1.1.1.1" ])
  end

  test "complete event includes subcommand" do
    @logger.start("modify.kamal", "id", command: "app", subcommand: "boot", hosts: [ "1.1.1.1" ])
    Dash::OtelShipper.any_instance.expects(:event).with("kamal.complete", "kamal.command": "app boot", "kamal.runtime": anything)
    @logger.finish("modify.kamal", "id", command: "app", subcommand: "boot")
  end

  test "failed event includes subcommand with error severity and exception attributes" do
    @logger.start("modify.kamal", "id", command: "app", subcommand: "boot", hosts: [ "1.1.1.1" ])
    Dash::OtelShipper.any_instance.expects(:event).with("kamal.failed",
      severity: :error, "kamal.command": "app boot", "kamal.runtime": anything,
      "exception.type": "RuntimeError", "exception.message": "boom")
    @logger.finish("modify.kamal", "id", command: "app", subcommand: "boot", exception: [ "RuntimeError", "boom" ])
  end

  test "finish prints endpoint" do
    @logger.start("modify.kamal", "id", command: "deploy", hosts: [ "1.1.1.1" ])

    output = capture_io { @logger.finish("modify.kamal", "id", command: "deploy") }.first
    assert_match /Logs sent to http:\/\/localhost:4318/, output
  end

  test "every phase of a deploy is shipped as its own event" do
    @logger.start("modify.kamal", "id", command: "deploy", hosts: [ "1.1.1.1" ])
    Dash::OtelShipper.any_instance.stubs(:event)
    Dash::OtelShipper.any_instance.expects(:event).with("dash.phase",
      "dash.phase.name": "Boot", "dash.phase.depth": 0, "dash.phase.seconds": 55.2,
      "dash.phase.commands": 12, "dash.phase.command_seconds": 41.0, "dash.phase.connect_seconds": 1.2,
      "deployment.id": anything, "deployment.name": "deploy myapp")

    @logger.finish("modify.kamal", "id", command: "deploy", report: report)
  end

  test "the build ships one summary event and one event per Dockerfile step" do
    @logger.start("modify.kamal", "id", command: "deploy", hosts: [ "1.1.1.1" ])
    Dash::OtelShipper.any_instance.stubs(:event)
    Dash::OtelShipper.any_instance.expects(:event).with("dash.build",
      "dash.build.cached_steps": 0, "dash.build.total_steps": 1, "dash.build.export_seconds": 0.0,
      "dash.build.cache_export_seconds": 0.0, "dash.build.push_seconds": 0.0,
      "deployment.id": anything, "deployment.name": "deploy myapp")
    Dash::OtelShipper.any_instance.expects(:event).with("dash.build.step",
      "dash.build.stage": "build", "dash.build.ordinal": 1, "dash.build.instruction": "RUN bundle install",
      "dash.build.seconds": 84.1, "dash.build.cached": false,
      "deployment.id": anything, "deployment.name": "deploy myapp")

    @logger.finish("modify.kamal", "id", command: "deploy", report: report)
  end

  test "each piece of advice is shipped so a backend can chart what dash keeps saying" do
    @logger.start("modify.kamal", "id", command: "deploy", hosts: [ "1.1.1.1" ])
    Dash::OtelShipper.any_instance.stubs(:event)
    Dash::OtelShipper.any_instance.expects(:event).with("dash.advice",
      "dash.advice.rule": "root-user", "dash.advice.severity": "info", "dash.advice.location": "Dockerfile:9",
      "dash.advice.message": "the final stage sets no USER",
      "deployment.id": anything, "deployment.name": "deploy myapp")

    @logger.finish("modify.kamal", "id", command: "deploy", report: report)
  end

  test "a command that carries no report ships only the events it always did" do
    @logger.start("modify.kamal", "id", command: "app", subcommand: "boot", hosts: [ "1.1.1.1" ])
    Dash::OtelShipper.any_instance.expects(:event).with("kamal.complete", "kamal.command": "app boot", "kamal.runtime": anything)

    @logger.finish("modify.kamal", "id", command: "app", subcommand: "boot")
  end

  # A backend that is unreachable, or a report shape a future dash changed, must not turn
  # a deploy that succeeded into one that failed.
  test "a report that cannot be shipped costs one line on stderr" do
    @logger.start("modify.kamal", "id", command: "deploy", hosts: [ "1.1.1.1" ])
    Dash::OtelShipper.any_instance.stubs(:event)
    Dash::Timings.any_instance.stubs(:to_h).raises(RuntimeError, "boom")

    assert_match "OTel report events failed: RuntimeError: boom",
      capture_io { @logger.finish("modify.kamal", "id", command: "deploy", report: report) }.last
  end

  test "stream output includes host, iostream and severity from thread context" do
    Thread.current[:kamal_host] = "1.1.1.1"
    Thread.current[:kamal_iostream] = "stdout"
    Thread.current[:kamal_severity] = Logger::DEBUG

    Dash::OtelShipper.any_instance.expects(:append).with("output line\n", host: "1.1.1.1", iostream: "stdout", severity: Logger::DEBUG)
    @logger << "output line\n"
  ensure
    Thread.current[:kamal_host] = nil
    Thread.current[:kamal_iostream] = nil
    Thread.current[:kamal_severity] = nil
  end

  test "stream output without thread context omits host, iostream and severity" do
    Dash::OtelShipper.any_instance.expects(:append).with("output line\n", host: nil, iostream: nil, severity: nil)
    @logger << "output line\n"
  end

  private
    def report
      timings = Dash::Timings.from_h([
        { name: "Boot", depth: 0, seconds: 55.2, commands: 12, command_seconds: 41.0, connect_seconds: 1.2, local: false } ])

      Dash::Report.new(timings: timings).tap do |report|
        report.build = Dash::Build::Report.new(steps: [ bundle_install_step ])
        report.advice = [ Dash::Dockerfile::Finding.new(rule: "root-user", severity: :info,
          location: "Dockerfile:9", message: "the final stage sets no USER") ]
      end
    end

    def bundle_install_step
      Dash::Build::Step.new(1, kind: :instruction).tap do |step|
        step.instruction = "RUN bundle install"
        step.stage, step.ordinal, step.steps_in_stage = "build", 1, 5
        step.seconds = 84.1
      end
    end
end
