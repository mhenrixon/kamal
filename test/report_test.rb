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

  test "advice prints under the table, warnings first, with the suggestion on its own line" do
    @timings.phase("Boot") { }
    @report.advice = [ finding(:warn, "Dockerfile:5", "COPY . . busts the install", "copy manifests first"),
                       finding(:info, "builder.cache", "cache export took 29.4s") ]

    assert_equal [
      "  Advice",
      "    warn  Dockerfile:5    COPY . . busts the install",
      "                          → copy manifests first",
      "    info  builder.cache   cache export took 29.4s"
    ], @report.lines.drop(1)
  end

  test "no advice means no Advice header" do
    @timings.phase("Boot") { }
    @report.advice = []

    assert_equal @timings.lines, @report.lines
  end

  test "warnings are yellow on a terminal and plain everywhere else" do
    @report.advice = [ finding(:warn, "Dockerfile:5", "message"), finding(:info, "Dockerfile:6", "message") ]

    $stdout.stub(:tty?, true) do
      warning, note = @report.advice_lines.drop(1)
      assert_match "\e[33m", warning
      assert_no_match(/\e\[/, note)
    end
  end

  test "analyze! reads the configured Dockerfile and honours the ignore list" do
    @report.analyze! config(dockerfile: "test/fixtures/dockerfiles/naive_single_stage.Dockerfile", ignore: [ "root-user" ])

    assert_includes @report.advice.map(&:rule), "copy-before-install"
    assert_not_includes @report.advice.map(&:rule), "root-user"
  end

  test "analyze! measures against the build report when there is one" do
    @report.build = Dash::Build::Report.new(steps: [ bundle_install_step ])
    @report.analyze! config(dockerfile: "test/fixtures/dockerfiles/naive_single_stage.Dockerfile")

    assert_match "(measured 84.1s uncached)", @report.advice.find { |f| f.rule == "copy-before-install" }.message
  end

  test "analyze! does nothing when advice is turned off" do
    @report.analyze! config(dockerfile: "test/fixtures/dockerfiles/naive_single_stage.Dockerfile", advice: false)

    assert_empty @report.advice
  end

  test "analyze! stays quiet when there is no Dockerfile to read" do
    @report.analyze! config(dockerfile: "test/fixtures/dockerfiles/nonexistent.Dockerfile")

    assert_empty @report.advice
  end

  private
    def finding(severity, location, message, suggestion = nil)
      Dash::Dockerfile::Finding.new(rule: "rule", severity: severity, location: location, message: message, suggestion: suggestion)
    end

    def bundle_install_step
      Dash::Build::Step.new(1, kind: :instruction).tap do |step|
        step.instruction = "RUN bundle install"
        step.stage = "stage-0"
        step.ordinal, step.steps_in_stage = 1, 1
        step.seconds = 84.1
      end
    end

    def config(dockerfile:, ignore: [], advice: true)
      Dash::Configuration.new({
        service: "app", image: "dhh/app",
        registry: { "username" => "dhh", "password" => "secret" },
        builder: { "arch" => "amd64", "dockerfile" => dockerfile, "context" => "test/fixtures/dockerfiles/context" },
        report: { "advice" => advice, "hadolint" => false, "ignore" => ignore },
        servers: [ "1.1.1.1" ]
      })
    end

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
