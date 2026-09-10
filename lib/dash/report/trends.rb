# Compares this run with the last few saved reports of the same command and destination.
#
# The Dockerfile rules can only see what one build looked like; these see what a project's
# deploys usually look like, which is the only way to tell "the build takes 84 seconds"
# from "the build suddenly takes twice what it used to". Everything here is informational:
# a slow deploy is a fact about today, not a defect to fix.
#
# The phase names are the ones a deploy records in Dash::Cli::Main and Dash::Cli::Base.
# They are pinned from the other side by test/cli/main_test.rb, which asserts the table a
# real deploy prints, so a rename cannot quietly turn these rules off.
class Dash::Report::Trends
  BUILD_PHASE = "Build and push app image".freeze
  BOOT_PHASE = "Boot".freeze
  # Everything a deploy spends before and around the work itself: loading the gem, parsing
  # the config, resolving secrets, and taking the locks.
  OVERHEAD_PHASES = [ "Startup (load, config)", "Validate config and secrets",
                      "Acquire deploy lock", "Acquire server lock" ].freeze

  # Two deploys are an anecdote. Three are the fewest that can have a median worth
  # comparing against.
  MINIMUM_HISTORY = 3
  WINDOW = 5
  FACTOR = 1.5
  # Overhead this large is worth naming even to a project whose deploys have always
  # carried it — "normal" is not the same as "cheap".
  OVERHEAD_FLOOR = 10.0

  LOCATION = "deploy history".freeze

  def initialize(document, history: [], ignore: [])
    @document = document
    @history = comparable(history)
    @ignore = Array(ignore).map(&:to_s)
  end

  def findings
    return [] if @history.size < MINIMUM_HISTORY

    [ build_finding, boot_finding, overhead_finding, total_finding ].compact.reject { |finding| @ignore.include?(finding.rule) }
  end

  private
    def comparable(history)
      Array(history)
        .map { |document| document.transform_keys(&:to_sym) }
        .select { |document| document[:command] == @document[:command] && document[:status] == "succeeded" }
        .first(WINDOW)
    end

    def build_finding
      phase_finding "trend-build", "build", BUILD_PHASE
    end

    def boot_finding
      phase_finding "trend-boot", "boot", BOOT_PHASE
    end

    def phase_finding(rule, label, name)
      current = phase_seconds(@document, name) or return
      past = @history.filter_map { |document| phase_seconds(document, name) }
      return if past.size < MINIMUM_HISTORY || current <= median(past) * FACTOR

      note rule, "#{label} #{seconds(current)} vs median #{seconds(median(past))} over the last #{past.size} deploys"
    end

    def total_finding
      current = @document[:runtime].to_f
      past = @history.map { |document| document[:runtime].to_f }
      return if current <= median(past) * FACTOR

      note "trend-total", "total #{seconds(current)} vs median #{seconds(median(past))} over the last #{past.size} deploys"
    end

    # Fires on the absolute number as well as the trend, and names the row responsible —
    # ten seconds before the first docker command is nearly always one slow thing (a
    # secrets adapter shelling out, a lock waiting on a sweep) rather than a diffuse cost.
    def overhead_finding
      current = overhead_seconds(@document)
      past = @history.map { |document| overhead_seconds(document) }
      return if current < OVERHEAD_FLOOR && current <= median(past) * FACTOR

      message = "dash overhead #{seconds(current)} vs median #{seconds(median(past))} over the last #{past.size} deploys"
      if (slowest = slowest_overhead_phase)
        message += "; #{slowest[:name]} was #{seconds(slowest[:seconds])} of it"
      end

      note "trend-overhead", message, "a secrets adapter or a lock sweep is the usual cause"
    end

    def overhead_seconds(document)
      overhead_phases(document).sum { |phase| phase[:seconds].to_f }
    end

    def slowest_overhead_phase
      overhead_phases(@document).max_by { |phase| phase[:seconds].to_f }
    end

    def overhead_phases(document)
      Array(document[:phases])
        .map { |phase| phase.transform_keys(&:to_sym) }
        .select { |phase| OVERHEAD_PHASES.include?(phase[:name]) }
    end

    # Only depth-0 rows: a per-host row inside Boot is named after the host, but a role
    # could be named "Boot" and would otherwise be counted as the phase.
    def phase_seconds(document, name)
      phase = Array(document[:phases])
        .map { |candidate| candidate.transform_keys(&:to_sym) }
        .find { |candidate| candidate[:name] == name && candidate[:depth].to_i.zero? }

      phase[:seconds].to_f if phase
    end

    def median(values)
      sorted = values.sort
      middle = sorted.size / 2

      sorted.size.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
    end

    def seconds(value)
      format("%.1fs", value.to_f)
    end

    def note(rule, message, suggestion = nil)
      Dash::Dockerfile::Finding.new \
        rule: rule, severity: :info, location: LOCATION, message: message, suggestion: suggestion
    end
end
