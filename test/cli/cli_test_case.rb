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

      yield

      commands
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
