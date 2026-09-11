require "active_support/core_ext/string/filters"
require "active_support/core_ext/module/delegation"

# The deploy report: the phase table plus everything measured inside a phase that the
# table itself has no column for. Today that is the build; the Dockerfile advice and the
# JSON export hang off the same object.
#
# It owns the rendering rather than Timings because the build rows have to be spliced
# into the middle of the table, under the phase they belong to, and Timings has no
# business knowing what a buildx vertex is.
class Dash::Report
  delegate :human_bytes, to: Dash::Utils

  # Depth-1 rows, so build steps line up with the per-host rows a Boot phase prints.
  INDENT = "    "
  # Wider than the phase table's 36-column name, because a Dockerfile instruction is the
  # whole point of the row and most of them are longer than that. The build rows line up
  # with each other as their own block under the phase; 4 + 60 + 8 still fits 80 columns.
  NAME_WIDTH = 60
  VALUE_WIDTH = 7
  SLOWEST_STEPS = 5

  # Severity, then the file or key to open, then the sentence. The suggestion hangs under
  # the sentence so the eye can skip the whole block or read one finding in full.
  SEVERITY_WIDTH = 4
  LOCATION_WIDTH = 15
  SEVERITY_COLORS = { warn: "\e[33m" }.freeze

  # The version of the JSON documents #to_h writes and #from_h reads. Bumping it is a
  # promise to whatever reads .dash/reports, so a reader that does not recognise the
  # number skips the file rather than guessing.
  SCHEMA = 1

  attr_reader :timings
  attr_accessor :build, :build_entry, :advice

  # Rebuilds a saved report so `dash report` prints it the way the deploy printed it —
  # same table, same build rows under the same phase, same advice.
  def self.from_h(document)
    document = document.transform_keys(&:to_sym)
    timings = Dash::Timings.from_h(document[:phases])

    new(timings: timings).tap do |report|
      report.build_entry = timings.entry_at(document[:build_phase])
      report.build = Dash::Build::Report.from_h(document[:build]) if document[:build]
      report.advice = Array(document[:advice]).map { |finding| Dash::Dockerfile::Finding.from_h(finding) }
    end
  end

  def initialize(timings:)
    @timings = timings
    @advice = []
  end

  # The run's own facts (command, service, destination, version, timings of the whole
  # thing) belong to the caller that knows them; the report contributes what it measured.
  # `build_phase` is the row the build rows hang under, by position, so a reader can put
  # them back without matching on a phase name dash is free to reword.
  def to_h(**run)
    {
      schema: SCHEMA, dash_version: Dash::VERSION, **run,
      phases: timings.to_h, build_phase: build_entry && timings.index_of(build_entry),
      build: build&.to_h, advice: advice.map(&:to_h)
    }.compact
  end

  def lines
    lines = timings.lines
    rows = build_lines

    unless rows.empty?
      index = build_entry && timings.index_of(build_entry)
      lines = index ? lines.insert(index + 1, *rows) : lines + rows
    end

    lines + advice_lines
  end

  # Runs the Dockerfile rules against the file this deploy would build, upgraded with what
  # the build measured when there was one. Silent about a Dockerfile that is not there:
  # a --skip-push deploy never looks at one, and a missing file is `dash doctor`'s finding
  # to report, not a deploy's.
  #
  # `build_directory` is where the Dockerfile and context are read from: the git clone for
  # a `push`, the working directory for a `dev` build that never clones.
  def analyze!(config, build: @build, build_directory: config.builder.build_directory)
    @advice = []
    return unless config.report.advice?

    dockerfile = File.expand_path(config.builder.dockerfile, build_directory)
    return unless File.exist?(dockerfile)

    @advice = Dash::Dockerfile::Analyzer.new(
      document: Dash::Dockerfile::Parser.parse(File.read(dockerfile)),
      path: config.builder.dockerfile,
      file: dockerfile,
      context_dir: File.expand_path(config.builder.context, build_directory),
      build: build,
      builder: config.builder,
      ignore: config.report.ignore,
      hadolint: config.report.hadolint?
    ).findings
  end

  # Also printed on their own by `dash build push`, for the same reason the build rows are.
  def advice_lines
    return [] if advice.blank?

    [ "  Advice", *advice.flat_map { |finding| advice_rows(finding) } ]
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
    # The suggestion hangs under the message rather than under the row, so a location
    # longer than its column (a Dockerfile somewhere deep in the tree) shifts both.
    def advice_rows(finding)
      prefix = format("%s%-#{SEVERITY_WIDTH}s  %-#{LOCATION_WIDTH}s ", INDENT, finding.severity, finding.location)

      rows = [ colorize(finding.severity, "#{prefix}#{finding.message}") ]
      rows << "#{" " * prefix.length}→ #{finding.suggestion}" if finding.suggestion.present?
      rows
    end

    # Colour is for the terminal only: a report piped to a file or asserted in a test
    # should be the same text without the escape codes.
    def colorize(severity, line)
      color = SEVERITY_COLORS[severity] if $stdout.tty?
      color ? "#{color}#{line}\e[0m" : line
    end

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
end
