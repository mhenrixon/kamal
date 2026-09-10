require "test_helper"

# `lib/dash/sshkit_with_ext.rb` stamps every command and every SSH connect onto the
# timing entry that is current on the issuing thread. The interesting part is the
# threads: SSHKit runs one per host, and a thread starts with none of its parent's
# thread-locals, so without explicit propagation every boot command would be attributed
# to nothing at all.
class SshkitTimingTest < ActiveSupport::TestCase
  include SSHKit::DSL

  setup do
    Object.send(:remove_const, :DASH)
    Object.const_set(:DASH, Dash::Commander.new)
  end

  teardown do
    Thread.current[Dash::Timings::CURRENT_KEY] = nil
  end

  test "a remote command is attributed to the current phase" do
    DASH.timings.phase("Boot") do
      quietly { on("1.1.1.1") { execute :docker, :ps } }
    end

    assert_match(/\A  Boot\s+\d+\.\ds\s+1 ssh\s+\d+\.\ds\z/, DASH.timings.lines.sole)
  end

  test "a local command is attributed as local" do
    DASH.timings.phase("Build and push app image") do
      quietly { run_locally { execute :docker, :buildx, :build } }
    end

    assert_match(/1 local\s+\d+\.\ds\z/, DASH.timings.lines.sole)
  end

  test "commands issued outside a phase are not attributed" do
    quietly { on("1.1.1.1") { execute :docker, :ps } }

    assert_not DASH.timings.any?
  end

  test "a host thread inherits the entry that was current when the runner started" do
    seen = nil

    DASH.timings.phase("Boot") do |entry|
      quietly do
        on("1.1.1.1") do
          seen = DASH.timings.current
        end
      end

      assert_same entry, seen
    end
  end

  test "commands land on the host phase opened inside the host thread" do
    DASH.timings.phase("Boot") do
      quietly do
        on([ "1.1.1.1", "1.1.1.2" ]) do |host|
          DASH.timings.phase("web #{host}", depth: 1) { execute :docker, :ps }
        end
      end
    end

    boot, *hosts = DASH.timings.lines

    assert_equal 2, hosts.size
    assert_match(/\A  Boot\s+\d+\.\ds\s+2 ssh\s+\d+\.\ds\z/, boot)
    assert hosts.all? { |line| line.match?(/\A    web 1\.1\.1\.\d\s+\d+\.\ds\s+1 ssh\s+\d+\.\ds\z/) }, hosts.inspect
  end

  test "roles run through on_roles inherit the current entry too" do
    seen = Queue.new

    DASH.timings.phase("Boot") do |entry|
      quietly do
        on_roles(roles_for("1.1.1.1", "1.1.1.2"), hosts: [ "1.1.1.1", "1.1.1.2" ]) do |host, role|
          seen << DASH.timings.current
        end
      end

      assert_equal [ entry, entry ], Array.new(2) { seen.pop }
    end
  end

  private
    def quietly(&block)
      capture(:stdout, &block)
    end

    def roles_for(*hosts)
      hosts.map do |host|
        Struct.new(:name, :hosts) do
          def to_s = name
        end.new(host, [ host ])
      end
    end
end
