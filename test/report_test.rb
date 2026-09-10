require "test_helper"

class ReportTest < ActiveSupport::TestCase
  setup do
    @timings = Dash::Timings.new
    @report = Dash::Report.new(timings: @timings)
  end

  teardown do
    Thread.current[:dash_timing_entry] = nil
  end

  test "without a build the report is just the timing table" do
    @timings.phase("Boot") { }

    assert_equal @timings.lines, @report.lines
  end

  test "build rows print under the build phase, not at the end of the table" do
    @timings.phase("Validate config and secrets") { }
    @timings.phase("Build and push app image") { |entry| @report.build_entry = entry }
    @timings.phase("Boot") { }
    @report.build = build_report

    assert_equal \
      [ "Validate config and secrets", "Build and push app image", "build context",
        "[build 1/5] RUN bundle install", "[build 2/5] RUN rake assets:precompile",
        "cached steps", "export + push", "Boot" ],
      @report.lines.map { |line| line.strip.split(/\s{2,}/).first }
  end

  test "build rows align with the depth-1 rows of the timing table" do
    @timings.phase("Build and push app image") { |entry| @report.build_entry = entry }
    @report.build = build_report

    assert_equal "    build context                                                   0.2s (25.2MB)", @report.lines[1]
    assert_equal "    [build 1/5] RUN bundle install                                 84.1s", @report.lines[2]
    assert_equal "    cached steps                                                 9 of 11", @report.lines[4]
    assert_equal "    export + push                                                  20.0s (cache export 29.4s)", @report.lines[5]
  end

  test "the cache export note is dropped when nothing was exported to cache" do
    @timings.phase("Build and push app image") { |entry| @report.build_entry = entry }
    @report.build = build_report(cache_export: 0.0)

    assert_equal "    export + push                                                  20.0s", @report.lines.last
  end

  test "rows whose value is zero are omitted" do
    @timings.phase("Build and push app image") { |entry| @report.build_entry = entry }
    @report.build = Dash::Build::Report.new(steps: [ instruction(4, 4.0) ])

    assert_equal [ "Build and push app image", "[build 4/5] RUN step 4", "cached steps" ],
      @report.lines.map { |line| line.strip.split(/\s{2,}/).first }
  end

  test "a failing step is named so the operator does not have to scroll back" do
    @timings.phase("Build and push app image") { |entry| @report.build_entry = entry }
    broken = instruction(4, nil)
    broken.error = "process \"/bin/sh -c bundle install\" did not complete successfully: exit code: 1"
    @report.build = Dash::Build::Report.new(steps: [ broken ])

    assert_match /\A    \[build 4\/5\] RUN step 4\s+error \(process /, @report.lines.last
  end

  test "a context transfer with no DONE reports its size and no fabricated duration" do
    @timings.phase("Build and push app image") { |entry| @report.build_entry = entry }
    unfinished = context(340_120_000, nil)
    @report.build = Dash::Build::Report.new(steps: [ unfinished ])

    assert_equal "    build context                                                    n/a (340.1MB)", @report.lines[1]
  end

  test "the same failure on every platform of a multi-platform build prints one row" do
    @timings.phase("Build and push app image") { |entry| @report.build_entry = entry }
    amd64, arm64 = instruction(1, nil), instruction(1, nil)
    amd64.platform, arm64.platform = "linux/amd64", "linux/arm64"
    amd64.error = arm64.error = "did not complete successfully: exit code: 1"
    @report.build = Dash::Build::Report.new(steps: [ amd64, arm64 ])

    assert_equal 1, @report.lines.count { |line| line.include?("error") }
  end

  test "different steps failing with the same message each get a row" do
    @timings.phase("Build and push app image") { |entry| @report.build_entry = entry }
    first, second = instruction(1, nil), instruction(4, nil)
    first.error = second.error = "did not complete successfully: exit code: 1"
    @report.build = Dash::Build::Report.new(steps: [ first, second ])

    assert_equal 2, @report.lines.count { |line| line.include?("error") }
  end

  test "different failures on the same step still each get a row" do
    @timings.phase("Build and push app image") { |entry| @report.build_entry = entry }
    first, second = instruction(1, nil), instruction(1, nil)
    first.error = "exit code: 1"
    second.error = "exit code: 2"
    @report.build = Dash::Build::Report.new(steps: [ first, second ])

    assert_equal 2, @report.lines.count { |line| line.include?("error") }
  end

  test "a long instruction is capped so one row cannot run off the terminal" do
    @timings.phase("Build and push app image") { |entry| @report.build_entry = entry }
    long = instruction(1, 4.0)
    long.instruction = "RUN #{"very-long-command " * 10}"
    @report.build = Dash::Build::Report.new(steps: [ long ])

    assert_equal 4 + 60 + 8, @report.lines[1].length
  end

  test "an empty build report adds no rows" do
    @timings.phase("Build and push app image") { |entry| @report.build_entry = entry }
    @report.build = Dash::Build::Report.new

    assert_equal @timings.lines, @report.lines
  end

  test "build rows are appended when no build phase claimed them" do
    @timings.phase("Boot") { }
    @report.build = build_report

    assert_equal "Boot", @report.lines.first.strip.split(/\s{2,}/).first
    assert_equal "export + push", @report.lines.last.strip.split(/\s{2,}/).first
  end

  test "build_lines stand alone for a build outside a deploy" do
    @report.build = build_report

    assert_equal @report.lines, @report.build_lines
  end

  private
    def build_report(cache_export: 29.4)
      steps = [
        context(25_180_000, 0.2),
        instruction(1, 84.1),
        instruction(2, 12.0),
        *Array.new(9) { |i| instruction(i + 3, 0.0, cached: true) },
        vertex(:export, 20.0),
        vertex(:cache_export, cache_export)
      ]

      Dash::Build::Report.new(steps: steps)
    end

    def instruction(ordinal, seconds, cached: false)
      Dash::Build::Step.new(ordinal, kind: :instruction).tap do |step|
        step.stage = "build"
        step.ordinal = ordinal
        step.steps_in_stage = 5
        step.instruction = { 1 => "RUN bundle install", 2 => "RUN rake assets:precompile" }.fetch(ordinal, "RUN step #{ordinal}")
        step.seconds = seconds
        step.cached = cached
      end
    end

    def context(bytes, seconds)
      Dash::Build::Step.new(98, kind: :context, name: "[internal] load build context").tap do |step|
        step.bytes = bytes
        step.seconds = seconds
      end
    end

    def vertex(kind, seconds)
      Dash::Build::Step.new(97, kind: kind, name: kind.to_s).tap { |step| step.seconds = seconds }
    end
end
