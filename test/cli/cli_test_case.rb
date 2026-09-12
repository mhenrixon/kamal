require "test_helper"

class CliTestCase < ActiveSupport::TestCase
  setup do
    ENV["VERSION"]             = "999"
    ENV["RAILS_MASTER_KEY"]    = "123"
    ENV["MYSQL_ROOT_PASSWORD"] = "secret123"
    Object.send(:remove_const, :DASH)
    Object.const_set(:DASH, Dash::Commander.new)
    Dash::Cli::Base.legacy_project_directory_warned = false

    # Ensure no loadbalancer functionality interferes with tests
    Dash::Configuration::Proxy.any_instance.stubs(:load_balancing?).returns(false)

    # Every deploy saves a JSON report. The path is relative to the working directory, so
    # without this the suite would write .dash/reports into this repository — and the
    # trend rules would start comparing test runs with each other.
    @reports_directory = Dir.mktmpdir
    Dash::Cli::Base.any_instance.stubs(:reports_directory).returns(@reports_directory)
  end

  teardown do
    ENV.delete("RAILS_MASTER_KEY")
    ENV.delete("MYSQL_ROOT_PASSWORD")
    ENV.delete("VERSION")
    FileUtils.rm_rf @reports_directory
  end

  private
    # Every command the Printer backend was handed during the block, in order. Only what a
    # caller `execute`s arrives here - a capture whose `capture_with_info` is stubbed is
    # intercepted above this layer and never shows up, so a round-trip count that has to
    # see captures must count those instead.
    def recorded_commands
      commands = []
      SSHKit::Backend::Printer.any_instance.stubs(:execute_command).with { |cmd| commands << cmd.to_command; true }

      begin
        yield
      ensure
        # The stub swallows the command instead of printing it, and mocha would leave it
        # standing until the end of the test - so anything run after the block would be
        # silently invisible. Recording stops where the block does.
        SSHKit::Backend::Printer.any_instance.unstub(:execute_command)
      end

      commands
    end

    # Every command captured during the block, in order. Recorded by a matcher that never
    # matches, so whichever stub was going to answer the capture still answers it — mocha
    # tries expectations newest first, which is why this has to be set up last.
    def recorded_captures
      captures = []
      SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info).with { |*args| captures << args.join(" "); false }

      yield

      captures
    end

    # #recorded_commands and #recorded_captures each answer one half of what a host was
    # asked to do; a caller that needs both interleaved in the order they actually ran -
    # a round-trip count, where an execute and a capture cost the same SSH round trip -
    # cannot get that by nesting the two, since each keeps its own array. This shares one
    # array between both stubs instead. Formats captures without their trailing options
    # hash (`raise_on_non_zero_exit: false` and friends), which reads as noise next to a
    # shell command; #recorded_captures keeps the hash for its own callers.
    def recorded_commands_and_captures
      round_trips = []
      SSHKit::Backend::Printer.any_instance.stubs(:execute_command).with { |cmd| round_trips << cmd.to_command; true }
      SSHKit::Backend::Abstract.any_instance.stubs(:capture_with_info)
        .with { |*args| round_trips << args.reject { |arg| arg.is_a?(Hash) }.join(" "); false }

      begin
        yield
      ensure
        SSHKit::Backend::Printer.any_instance.unstub(:execute_command)
      end

      round_trips
    end

    # The id `docker run --detach` prints, which a boot reads instead of asking docker for
    # the container id in a round trip of its own.
    def stub_run_capture(id: "123")
      stub_capture { |args| docker_run?(args) }.returns(id)
    end

    # The readiness wait a boot runs on the host for a role without a proxy: one round trip
    # that blocks there until the container is ready or the deadline passes. Each status is
    # what one wait returned; the last repeats.
    def stub_readiness_wait(*statuses, expect: false)
      stub_capture(expect: expect) { |args| readiness_wait?(args) }.returns(*statuses)
    end

    # The plain status read the poller makes to confirm an unchecked container is still
    # running after its readiness delay — the only readiness round trip left beside the wait.
    def stub_readiness_confirm(*statuses, expect: false)
      stub_capture(expect: expect) { |args| readiness_confirm?(args) }.returns(*statuses)
    end

    # Answers one kind of capture, and echoes the command it answered into the stream
    # `stdouted` reads. The echo is the point: a stubbed capture is intercepted above the
    # Printer and never printed, so without it every assertion about what a boot ran would
    # go blind the moment that command moved from `execute` to `capture`.
    def stub_capture(expect: false, &matcher)
      backend = SSHKit::Backend::Abstract.any_instance
      expectation = expect ? backend.expects(:capture_with_info) : backend.stubs(:capture_with_info)

      expectation
        .with { |*args| matcher.call(args).tap { |matched| SSHKit.config.output.info(args.join(" ")) if matched } }
        .tap { |it| it.at_least_once if expect }
    end

    def docker_run?(args)
      args.first == :docker && args[1] == :run
    end

    def readiness_wait?(args)
      args.first == :sh && args.join(" ").include?(Dash::Commands::Base::READINESS_PROGRESS_PREFIX)
    end

    def readiness_confirm?(args)
      args.first == :docker && args.include?(Dash::Commands::Base::DOCKER_HEALTH_STATUS_FORMAT)
    end

    # A real `docker buildx build --progress=plain` stream, parsed by the same handler a
    # build attaches. Cheaper than a Docker daemon and it proves the wiring end to end.
    def build_report_from_fixture(name = "progress_plain_success")
      Dash::Build::ProgressParser.new.tap do |parser|
        parser.on_data(nil, :stdout, File.read("test/fixtures/build/#{name}.log"), nil)
        parser.finish
      end.result
    end

    def fail_hook(hook)
      @executions = []
      Dash::Commands::Hook.any_instance.stubs(:hook_exists?).returns(true)

      SSHKit::Backend::Abstract.any_instance.stubs(:execute)
        .with { |*args| @executions << args; args != [ ".dash/hooks/#{hook}" ] }
      SSHKit::Backend::Abstract.any_instance.stubs(:execute)
        .with { |*args| args.first == ".dash/hooks/#{hook}" }
        .raises(SSHKit::Command::Failed.new("failed"))
    end

    def stub_setup
      SSHKit::Backend::Abstract.any_instance.stubs(:execute)
        .with { |*args| args == [ :mkdir, "-p", ".dash/apps/app" ] }
      SSHKit::Backend::Abstract.any_instance.stubs(:execute)
        .with { |arg1, arg2, arg3| arg1 == :mkdir && arg2 == "-p" && arg3 == ".dash/lock-app" }
      SSHKit::Backend::Abstract.any_instance.stubs(:execute)
        .with { |arg1, arg2| arg1 == :mkdir && arg2 == ".dash/lock-app" }
      SSHKit::Backend::Abstract.any_instance.stubs(:execute)
        .with { |arg1, arg2| arg1 == :rm && arg2 == ".dash/lock-app/details" }
      SSHKit::Backend::Abstract.any_instance.stubs(:execute)
        .with(:docker, :buildx, :inspect, "kamal-local-docker-container")
    end

    def assert_hook_ran(hook, output, count: 1)
      regexp = ([ "/usr/bin/env .dash/hooks/#{hook}" ] * count).join(".*")
      assert_match /#{regexp}/m, output
    end

    def with_argv(*argv)
      old_argv = ARGV
      ARGV.replace(*argv)
      yield
    ensure
      ARGV.replace(old_argv)
    end

    def with_build_directory
      build_directory = File.join Dir.tmpdir, "kamal-clones", "app-#{pwd_sha}", File.basename(Dash::Git.root)
      FileUtils.mkdir_p build_directory
      FileUtils.touch File.join build_directory, "Dockerfile"
      yield build_directory + "/"
    ensure
      FileUtils.rm_rf build_directory
    end

    def pwd_sha
      Digest::SHA256.hexdigest(Dir.pwd)[0..12]
    end
end
