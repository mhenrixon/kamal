require "active_support/core_ext/string/filters"

# The deploy report: the phase table plus everything measured inside a phase that the
# table itself has no column for. Today that is the build; the Dockerfile advice and the
# JSON export hang off the same object.
#
# It owns the rendering rather than Timings because the build rows have to be spliced
# into the middle of the table, under the phase they belong to, and Timings has no
# business knowing what a buildx vertex is.
class Dash::Report
  # Depth-1 rows, so build steps line up with the per-host rows a Boot phase prints.
  INDENT = "    "
  # Wider than the phase table's 36-column name, because a Dockerfile instruction is the
  # whole point of the row and most of them are longer than that. The build rows line up
  # with each other as their own block under the phase; 4 + 60 + 8 still fits 80 columns.
  NAME_WIDTH = 60
  VALUE_WIDTH = 7
  SLOWEST_STEPS = 5

  attr_reader :timings
  attr_accessor :build, :build_entry

  def initialize(timings:)
    @timings = timings
  end

  def lines
    lines = timings.lines
    rows = build_lines
    return lines if rows.empty?

    index = build_entry && timings.index_of(build_entry)
    index ? lines.insert(index + 1, *rows) : lines + rows
  end

  # Also printed on their own by `dash build push`, which has no phase table to sit under.
  def build_lines
    return [] unless build&.any?

    rows = []
    rows << context_row if build.context_bytes
    build.slowest(SLOWEST_STEPS).select(&:seconds).each { |step| rows << row(step.label, seconds(step.seconds)) }
    rows << row("cached steps", "#{build.cached_steps.size} of #{build.dockerfile_steps.size}") if build.dockerfile_steps.any?
    rows << export_row if export_and_push_seconds > 0
    # A multi-platform build runs the same instruction once per platform, so one broken
    # step fails once per platform with the same message. Print that once.
    build.failed_steps.uniq { |step| [ step.label, step.error ] }.each { |step| rows << row(step.label, "error", step.error) }
    rows
  end

  private
    # A build killed between the context transfer and that vertex's DONE has a size but
    # no duration. "0.0s" would be a measurement nobody took.
    def context_row
      row "build context", build.context_seconds ? seconds(build.context_seconds) : "n/a", human_bytes(build.context_bytes)
    end

    def export_row
      note = "cache export #{seconds(build.cache_export_seconds)}" if build.cache_export_seconds > 0
      row "export + push", seconds(export_and_push_seconds), note
    end

    def export_and_push_seconds
      build.export_seconds + build.push_seconds
    end

    # Indented like a Dash::Timings depth-1 row, with a wider name column of its own; a
    # step longer than that is cut rather than allowed to run off the line.
    def row(name, value, detail = nil)
      line = format("%s%-#{NAME_WIDTH}s %#{VALUE_WIDTH}s", INDENT, name.truncate(NAME_WIDTH), value)
      detail ? "#{line} (#{detail})" : line
    end

    def seconds(value)
      format("%.1fs", value.to_f)
    end

    # buildx reports decimal units, so the report does too — an operator comparing the
    # row with what buildx printed should see the same number.
    def human_bytes(bytes)
      divisor, unit = [ [ 1_000_000_000, "GB" ], [ 1_000_000, "MB" ], [ 1_000, "kB" ] ].find { |size, _| bytes >= size }
      divisor ? format("%.1f%s", bytes.to_f / divisor, unit) : "#{bytes}B"
    end
end
