require "test_helper"

class TimingsTest < ActiveSupport::TestCase
  setup do
    @timings = Dash::Timings.new
  end

  teardown do
    Thread.current[:dash_timing_entry] = nil
  end

  test "empty by default" do
    assert_not @timings.any?
    assert_equal [], @timings.lines
  end

  test "phase records its name and wall time" do
    @timings.phase("Pull app image") { }

    assert @timings.any?
    assert_match(/\A  Pull app image\s+\d+\.\ds\z/, @timings.lines.sole)
  end

  test "phase records even when the block raises" do
    assert_raises(RuntimeError) { @timings.phase("Boot") { raise "boom" } }

    assert_match(/Boot\s+\d+\.\ds/, @timings.lines.sole)
  end

  test "nested phases print as a tree in start order" do
    @timings.phase("Boot") do
      @timings.phase("web 1.1.1.1", depth: 1) { }
      @timings.phase("web 1.1.1.2", depth: 1) { }
    end

    assert_match(/\A  Boot\s+\d+\.\ds\z/, @timings.lines[0])
    assert_match(/\A    web 1\.1\.1\.1\s+\d+\.\ds\z/, @timings.lines[1])
    assert_match(/\A    web 1\.1\.1\.2\s+\d+\.\ds\z/, @timings.lines[2])
  end

  test "the block can annotate its entry" do
    @timings.phase("web 1.1.1.1") { |entry| entry.detail = "healthy after 0.5s" }

    assert_match(/web 1\.1\.1\.1\s+\d+\.\ds \(healthy after 0\.5s\)\z/, @timings.lines.sole)
  end

  test "phases from many threads all land" do
    threads = 20.times.map { |i| Thread.new { @timings.phase("host #{i}") { } } }
    threads.each(&:join)

    assert_equal 20, @timings.lines.size
  end

  test "record appends a pre-measured entry" do
    @timings.record("Startup (load, config)", 1.5)

    assert_match(/\A  Startup \(load, config\)\s+1\.5s\z/, @timings.lines.sole)
  end

  test "record takes a depth and a detail" do
    @timings.record("Startup", 1.0, depth: 1, detail: "gem load")

    assert_match(/\A    Startup\s+1\.0s \(gem load\)\z/, @timings.lines.sole)
  end

  test "current is the entry of the running phase and nil outside one" do
    assert_nil @timings.current

    @timings.phase("Boot") do |entry|
      assert_same entry, @timings.current
    end

    assert_nil @timings.current
  end

  test "phase restores the previous current entry even when the block raises" do
    @timings.phase("Boot") do |boot|
      assert_raises(RuntimeError) { @timings.phase("web", depth: 1) { raise "boom" } }

      assert_same boot, @timings.current
    end

    assert_nil @timings.current
  end

  test "a nested phase records its parent" do
    child = nil
    parent = nil

    @timings.phase("Boot") do |entry|
      parent = entry
      @timings.phase("web 1.1.1.1", depth: 1) { |nested| child = nested }
    end

    assert_same parent, child.parent
    assert_nil parent.parent
  end

  test "attributed commands print alongside the phase" do
    @timings.phase("Boot") do
      @timings.attribute_command(1.5, local: false)
      @timings.attribute_command(0.5, local: false)
    end

    assert_match(/\A  Boot\s+\d+\.\ds\s+2 ssh\s+2\.0s\z/, @timings.lines.sole)
  end

  test "local commands are labelled local" do
    @timings.phase("Build and push app image") { @timings.attribute_command(3.0, local: true) }

    assert_match(/1 local\s+3\.0s\z/, @timings.lines.sole)
  end

  test "a phase mixing local and remote commands is labelled ssh" do
    @timings.phase("Build and push app image") do
      @timings.attribute_command(3.0, local: true)
      @timings.attribute_command(1.0, local: false)
    end

    assert_match(/2 ssh\s+4\.0s\z/, @timings.lines.sole)
  end

  test "a parent sums the commands of its subtree while children keep their own" do
    @timings.phase("Boot") do
      @timings.attribute_command(1.0, local: false)

      @timings.phase("web 1.1.1.1", depth: 1) { @timings.attribute_command(2.0, local: false) }
      @timings.phase("web 1.1.1.2", depth: 1) { @timings.attribute_command(4.0, local: false) }
    end

    assert_match(/\A  Boot\s+\d+\.\ds\s+3 ssh\s+7\.0s\z/, @timings.lines[0])
    assert_match(/\A    web 1\.1\.1\.1\s+\d+\.\ds\s+1 ssh\s+2\.0s\z/, @timings.lines[1])
    assert_match(/\A    web 1\.1\.1\.2\s+\d+\.\ds\s+1 ssh\s+4\.0s\z/, @timings.lines[2])
  end

  test "a phase with no commands prints no command columns" do
    @timings.phase("Prune") { }

    assert_match(/\A  Prune\s+\d+\.\ds\z/, @timings.lines.sole)
  end

  test "commands print before the detail" do
    @timings.phase("web 1.1.1.1") do |entry|
      entry.detail = "healthy after 0.5s"
      @timings.attribute_command(1.0, local: false)
    end

    assert_match(/1 ssh\s+1\.0s \(healthy after 0\.5s\)\z/, @timings.lines.sole)
  end

  test "attributing outside a phase is a no-op" do
    @timings.attribute_command(1.0, local: false)
    @timings.attribute_connect(1.0)

    assert_not @timings.any?
  end

  test "connect seconds are attributed to the current entry" do
    @timings.phase("Boot") { @timings.attribute_connect(0.75) }

    assert_equal 0.75, @timings.to_h.sole[:connect_seconds]
  end

  test "index_of finds an entry's row by identity, not by value" do
    first = second = nil

    @timings.phase("Boot") { |entry| first = entry }
    @timings.phase("Boot") { |entry| second = entry }

    assert_equal 0, @timings.index_of(first)
    assert_equal 1, @timings.index_of(second)
    assert_nil @timings.index_of(Dash::Timings::Entry.new("Boot"))
  end

  test "to_h exports every entry with its subtree command totals" do
    @timings.record("Startup (load, config)", 1.0)

    @timings.phase("Boot") do
      @timings.phase("web 1.1.1.1", depth: 1) do |entry|
        entry.detail = "healthy after 0.5s"
        @timings.attribute_command(2.0, local: false)
        @timings.attribute_connect(0.25)
      end
    end

    startup, boot, host = @timings.to_h

    assert_equal "Startup (load, config)", startup[:name]
    assert_equal 0, startup[:depth]
    assert_equal 1.0, startup[:seconds]
    assert_nil startup[:detail]
    assert_equal 0, startup[:commands]

    assert_equal "Boot", boot[:name]
    assert_equal 1, boot[:commands]
    assert_equal 2.0, boot[:command_seconds]
    assert_equal 0.25, boot[:connect_seconds]
    assert_equal false, boot[:local]

    assert_equal "web 1.1.1.1", host[:name]
    assert_equal 1, host[:depth]
    assert_equal "healthy after 0.5s", host[:detail]
    assert_equal 1, host[:commands]
  end

  test "from_h rebuilds a table that renders the same lines" do
    @timings.record("Startup (load, config)", 1.0)

    @timings.phase("Boot") do
      @timings.phase("web 1.1.1.1", depth: 1) do |entry|
        entry.detail = "healthy after 0.5s"
        @timings.attribute_command(2.0, local: false)
        @timings.attribute_connect(0.25)
      end
    end

    assert_equal @timings.lines, Dash::Timings.from_h(@timings.to_h).lines
  end

  test "from_h keeps the exported subtree totals rather than summing them again" do
    @timings.phase("Boot") do
      @timings.phase("web 1.1.1.1", depth: 1) { @timings.attribute_command(2.0, local: false) }
    end

    assert_equal @timings.to_h, Dash::Timings.from_h(@timings.to_h).to_h
  end

  test "from_h accepts the string keys a JSON round trip leaves behind" do
    @timings.record("Startup (load, config)", 1.0)

    rebuilt = Dash::Timings.from_h(JSON.parse(JSON.generate(@timings.to_h)))

    assert_equal @timings.lines, rebuilt.lines
  end

  test "entry_at addresses a row by position so a build report can be reattached" do
    @timings.record("Startup (load, config)", 1.0)
    @timings.phase("Build and push app image") { }

    assert_equal "Build and push app image", @timings.entry_at(1).name
    assert_nil @timings.entry_at(9)
  end
end
