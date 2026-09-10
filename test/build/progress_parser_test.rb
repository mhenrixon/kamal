require "test_helper"

class BuildProgressParserTest < ActiveSupport::TestCase
  test "a successful multi-stage build yields the operator's own steps in the order buildx ran them" do
    report = parse("progress_plain_success")

    assert_equal \
      [ [ "base", 1, "FROM" ], [ "base", 2, "WORKDIR" ],
        [ "build", 1, "RUN" ], [ "build", 2, "COPY" ], [ "build", 3, "RUN" ], [ "build", 4, "COPY" ], [ "build", 5, "RUN" ],
        [ "stage-2", 1, "COPY" ], [ "stage-2", 2, "COPY" ], [ "stage-2", 3, "RUN" ] ],
      report.dockerfile_steps.map { |step| [ step.stage, step.ordinal, step.instruction.split.first ] }
  end

  test "buildkit's own vertices are kept but never counted as dockerfile steps" do
    report = parse("progress_plain_success")

    assert_equal :context, report.context_step.kind
    assert_not report.context_step.dockerfile_step?
    assert_equal [ :metadata ], report.steps.select { |s| s.name.include?("load metadata") }.map(&:kind)
  end

  test "instruction text is collapsed onto one line" do
    report = parse("progress_plain_success")

    assert_equal \
      "[build 1/5] RUN apt-get update -qq && apt-get install --no-install-recommends -y build-essential && rm -rf /var/lib/apt/lists/*",
      step(report, "build", 1).label
  end

  test "step seconds come from the last DONE line for the vertex" do
    report = parse("progress_plain_success")

    # #10 reports DONE three times as its layers extract: 2.5s, 2.8s, 2.8s.
    assert_equal 2.8, step(report, "base", 1).seconds
    assert_equal 13.8, step(report, "build", 1).seconds
    assert_equal 3.1, step(report, "build", 5).seconds
  end

  test "the build context is measured in bytes and seconds" do
    report = parse("progress_plain_success")

    assert_equal 25_180_000, report.context_bytes
    assert_equal 0.2, report.context_seconds
  end

  test "the dockerignore vertex does not masquerade as the build context" do
    report = parse("progress_plain_cached")

    assert_equal 1_560, report.context_bytes
  end

  test "CACHED marks a step cached with no seconds spent" do
    report = parse("progress_plain_cached")

    assert_equal 9, report.cached_steps.size
    assert_equal [ "FROM" ], report.uncached_steps.map { |step| step.instruction.split.first }
    assert_equal 0.0, step(report, "build", 3).seconds
    assert step(report, "build", 3).cached
  end

  test "export, push and cache export are separated" do
    report = parse("progress_plain_success")

    assert_equal 0.9, report.export_seconds
    assert_in_delta 0.3, report.push_seconds, 0.001
    assert_equal 7.2, report.cache_export_seconds
  end

  test "a failing step records the error and the report is still built" do
    report = parse("progress_plain_failed")

    error = report.errors.sole

    assert_equal "[4/5] RUN bundle install --frozen && exit 7", error.label
    assert_match /did not complete successfully: exit code: 16/, error.error
  end

  test "an unnamed stage keeps the ordinal buildx printed and no stage name" do
    report = parse("progress_plain_failed")

    assert_nil report.instruction_steps.first.stage
    assert_equal "[2/5] WORKDIR /rails", report.instruction_steps.first.label
  end

  test "a multi-platform build separates the platform from the stage" do
    report = parse("progress_plain_multiplatform")

    apk = report.instruction_steps.select { |s| s.instruction.start_with?("RUN apk") }

    assert_equal %w[ build build ], apk.map(&:stage)
    assert_equal %w[ linux/amd64 linux/arm64 ], apk.map(&:platform).sort
  end

  test "step output lines and layer progress are ignored" do
    report = parse("progress_plain_failed")

    assert_empty report.steps.select { |s| s.label.include?("Fetching gem metadata") }
  end

  test "the slowest uncached instruction steps come back longest first" do
    report = parse("progress_plain_success")

    assert_equal \
      [ 13.8, 3.1, 2.2, 0.5, 0.1 ],
      report.slowest(5).map(&:seconds)
  end

  test "data arriving in arbitrary chunks parses the same as whole lines" do
    whole = Dash::Build::ProgressParser.new
    chunked = Dash::Build::ProgressParser.new

    log = fixture("progress_plain_cached")
    whole.on_data(nil, :stdout, log, nil)
    log.each_char.each_slice(7) { |chars| chunked.on_data(nil, :stdout, chars.join, nil) }

    [ whole, chunked ].each(&:finish)

    assert_equal whole.result.to_h, chunked.result.to_h
  end

  test "a trailing line without a newline is still parsed" do
    parser = Dash::Build::ProgressParser.new
    parser.on_data(nil, :stdout, "#1 [build 1/1] RUN true\n#1 DONE 4.0s", nil)
    parser.finish

    assert_equal 4.0, parser.result.instruction_steps.sole.seconds
  end

  test "a parse failure is captured rather than raised into the build" do
    Dash::Build::Step.stubs(:new).raises(ArgumentError, "boom")

    parser = Dash::Build::ProgressParser.new
    parser.on_data(nil, :stdout, "#1 [build 1/1] RUN true\n", nil)
    parser.finish

    assert_kind_of ArgumentError, parser.error
    assert_empty parser.result.steps
  end

  test "an empty stream yields an empty report" do
    parser = Dash::Build::ProgressParser.new
    parser.finish

    assert_not parser.result.any?
  end

  private
    def fixture(name)
      File.read(File.expand_path("../fixtures/build/#{name}.log", __dir__))
    end

    def parse(name)
      parser = Dash::Build::ProgressParser.new
      parser.on_data(nil, :stdout, fixture(name), nil)
      parser.finish
      parser.result
    end

    def step(report, stage, ordinal)
      report.steps.find { |s| s.stage == stage && s.ordinal == ordinal }
    end
end
