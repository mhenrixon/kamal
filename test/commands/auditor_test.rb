require "test_helper"
require "active_support/testing/time_helpers"

class CommandsAuditorTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  setup do
    freeze_time

    @config = {
      service: "app", image: "dhh/app", registry: { "username" => "dhh", "password" => "secret" }, builder: { "arch" => "amd64" },  servers: [ "1.1.1.1" ]
    }

    @auditor = new_command
    @performer = Dash::Git.email.presence || `whoami`.chomp
    @recorded_at = Time.now.utc.iso8601
  end

  test "record" do
    assert_equal [
      *ENSURE_RUN_DIRECTORY, "&&",
      :echo,
      "\"[#{@recorded_at}] [#{@performer}] app removed container\"",
      ">>", ".dash/app-audit.log"
    ], @auditor.record("app removed container")
  end

  test "record_then puts the audit line and the action it describes in one command" do
    assert_equal [
      *ENSURE_RUN_DIRECTORY, "&&",
      :echo,
      "\"[#{@recorded_at}] [#{@performer}] Pruned images\"",
      ">>", ".dash/app-audit.log", "&&",
      :docker, :image, :prune, "&&",
      :docker, :image, :ls
    ], @auditor.record_then("Pruned images", [ :docker, :image, :prune ], [ :docker, :image, :ls ])
  end

  test "record_then with no action is just the audit line" do
    assert_equal @auditor.record("Pruned containers"), @auditor.record_then("Pruned containers")
  end

  test "record with destination" do
    new_command(destination: "staging").tap do |auditor|
      assert_equal [
        *ENSURE_RUN_DIRECTORY, "&&",
        :echo,
        "\"[#{@recorded_at}] [#{@performer}] [staging] app removed container\"",
        ">>", ".dash/app-staging-audit.log"
      ], auditor.record("app removed container")
    end
  end

  test "record with command details" do
    new_command(role: "web").tap do |auditor|
      assert_equal [
        *ENSURE_RUN_DIRECTORY, "&&",
        :echo,
        "\"[#{@recorded_at}] [#{@performer}] [web] app removed container\"",
        ">>", ".dash/app-audit.log"
      ], auditor.record("app removed container")
    end
  end

  test "record with arg details" do
    assert_equal [
      *ENSURE_RUN_DIRECTORY, "&&",
      :echo,
      "\"[#{@recorded_at}] [#{@performer}] [value] app removed container\"",
      ">>", ".dash/app-audit.log"
    ], @auditor.record("app removed container", detail: "value")
  end


  private
    def new_command(destination: nil, **details)
      Dash::Commands::Auditor.new(Dash::Configuration.new(@config, destination: destination, version: "123"), **details)
    end
end
