# Wall-clock accounting for a deploy, printed under "Finished all in". The total on its
# own says nothing about where the time went — a serialised boot, a slow pull, or a proxy
# waiting on a health check all look the same from the outside.
#
# Entries land in start order and carry a depth, so a parent phase (Boot) prints above
# the host entries it wraps even though the hosts finish first. Boot runs one thread per
# host, so every mutation is behind the mutex.
#
# Each entry also accounts for the commands issued while it was the current phase, which
# is what separates "the boot took 55s" from "the boot spent 41s of that in forty serial
# SSH round trips". Attribution is by thread-local: `phase` marks its entry as current for
# the duration of the block, and `lib/dash/sshkit_with_ext.rb` stamps every command and
# every SSH connect onto whatever entry is current on that thread. Nothing extra is
# executed — dash only measures the round trips it was already making.
class Dash::Timings
  # The entry the current thread is inside. SSHKit's per-host threads inherit it from
  # the thread that spawned them (see CompleteAll#execute and SSHKitDslRoles#on_roles),
  # so a command issued on a boot thread lands on that host's row.
  CURRENT_KEY = :dash_timing_entry

  Entry = Struct.new(:name, :seconds, :detail, :depth, :parent, :commands, :command_seconds, :connect_seconds, :local)

  # Read and written from lib/dash/sshkit_with_ext.rb, which hands the entry across the
  # per-host and per-role threads SSHKit spawns. Class-level because the patches run
  # without a commander in reach.
  class << self
    def current_entry
      Thread.current[CURRENT_KEY]
    end

    def current_entry=(entry)
      Thread.current[CURRENT_KEY] = entry
    end
  end

  def initialize
    @entries = []
    @mutex = Mutex.new
  end

  # Times the block. The entry is yielded so the block can annotate it — a boot can say
  # how long of its total was spent waiting for the container to become healthy.
  def phase(name, depth: 0)
    entry = new_entry(name, depth: depth)
    @mutex.synchronize { @entries << entry }
    started = clock

    previous = self.class.current_entry
    self.class.current_entry = entry

    begin
      yield entry
    ensure
      self.class.current_entry = previous
    end
  ensure
    entry.seconds = clock - started
  end

  # For time that was measured elsewhere — the gem load and config parse that happened
  # before there was a Timings to record into.
  def record(name, seconds, depth: 0, detail: nil)
    new_entry(name, depth: depth).tap do |entry|
      entry.seconds = seconds
      entry.detail = detail
      @mutex.synchronize { @entries << entry }
    end
  end

  def current
    self.class.current_entry
  end

  def attribute_command(seconds, local:)
    entry = current or return

    @mutex.synchronize do
      entry.commands += 1
      entry.command_seconds += seconds
      # A phase that issued even one remote command is reported as ssh: the local
      # label is only honest when nothing left the machine.
      entry.local &&= local
    end
  end

  def attribute_connect(seconds)
    entry = current or return

    @mutex.synchronize { entry.connect_seconds += seconds }
  end

  def any?
    @mutex.synchronize { @entries.any? }
  end

  # Where an entry's row sits in #lines, so Dash::Report can splice its build rows in
  # under the phase they belong to. Identity, not equality: two phases of the same name
  # and duration are equal as Structs but are not the same row.
  def index_of(entry)
    @mutex.synchronize { @entries.index { |candidate| candidate.equal?(entry) } }
  end

  def lines
    with_totals do |entry, totals|
      line = format("  %s%-36s %6.1fs", "  " * entry.depth, entry.name, entry.seconds.to_f)
      line += format(" %3d %-5s %5.1fs", totals[:commands], totals[:local] ? "local" : "ssh", totals[:command_seconds]) if totals[:commands] > 0
      entry.detail ? "#{line} (#{entry.detail})" : line
    end
  end

  # The command counts here are subtree totals, matching what the table prints — phases
  # nest, so a consumer must not sum them across depths.
  def to_h
    with_totals do |entry, totals|
      {
        name: entry.name,
        depth: entry.depth,
        seconds: entry.seconds.to_f,
        detail: entry.detail,
        commands: totals[:commands],
        command_seconds: totals[:command_seconds],
        connect_seconds: totals[:connect_seconds],
        local: totals[:local]
      }
    end
  end

  private
    def new_entry(name, depth:)
      Entry.new(name, nil, nil, depth, current, 0, 0.0, 0.0, true)
    end

    def with_totals
      @mutex.synchronize do
        totals = subtree_totals
        @entries.map { |entry| yield entry, totals[entry.object_id] }
      end
    end

    # A parent phase issues few commands of its own — Boot opens one thread per host and
    # then waits — so its own counters say nothing. Roll each entry's counters up through
    # its ancestors at render time rather than at record time, so the host rows keep
    # their own numbers while the parent shows what the phase cost in total.
    def subtree_totals
      totals = @entries.to_h { |entry| [ entry.object_id, { commands: 0, command_seconds: 0.0, connect_seconds: 0.0, local: true } ] }

      @entries.each do |entry|
        node = entry

        while node
          if (total = totals[node.object_id])
            total[:commands] += entry.commands
            total[:command_seconds] += entry.command_seconds
            total[:connect_seconds] += entry.connect_seconds
            total[:local] &&= entry.local if entry.commands > 0
          end

          node = node.parent
        end
      end

      totals
    end

    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
end
