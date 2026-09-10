require "test_helper"

class ReportTrendsTest < ActiveSupport::TestCase
  test "a build well over the median is worth saying out loud" do
    finding = findings(deploy(build: 84.0), history(build: [ 40.0, 41.0, 42.0 ])).find { |f| f.rule == "trend-build" }

    assert_equal :info, finding.severity
    assert_equal "build 84.0s vs median 41.0s over the last 3 deploys", finding.message
  end

  test "a build in line with the last few deploys says nothing" do
    assert_empty findings(deploy(build: 45.0), history(build: [ 40.0, 41.0, 42.0 ])).select { |f| f.rule == "trend-build" }
  end

  test "boot, total and overhead each get their own finding" do
    document = deploy(build: 40.0, boot: 90.0, runtime: 200.0, startup: 8.0, validate: 4.0)
    past = history(build: [ 40.0, 40.0, 40.0 ], boot: [ 30.0, 30.0, 30.0 ], runtime: [ 100.0, 100.0, 100.0 ],
      startup: [ 1.0, 1.0, 1.0 ], validate: [ 0.5, 0.5, 0.5 ])

    assert_equal %w[ trend-boot trend-overhead trend-total ], findings(document, past).map(&:rule).sort
  end

  test "the overhead finding names the row that dominated it" do
    document = deploy(runtime: 100.0, startup: 2.0, validate: 9.5)
    finding = findings(document, history(runtime: [ 100.0, 100.0, 100.0 ])).find { |f| f.rule == "trend-overhead" }

    assert_match "dash overhead 11.5s vs median 0.0s over the last 3 deploys", finding.message
    assert_match "Validate config and secrets was 9.5s of it", finding.message
  end

  # Ten seconds of gem load, config parse and lock acquisition is worth reporting even to
  # a project whose deploys have always been that slow.
  test "overhead over ten seconds is reported even when it is perfectly normal" do
    document = deploy(runtime: 100.0, startup: 11.0)
    past = history(runtime: [ 100.0, 100.0, 100.0 ], startup: [ 11.0, 11.0, 11.0 ])

    assert_includes findings(document, past).map(&:rule), "trend-overhead"
  end

  test "overhead under ten seconds and in line with history stays quiet" do
    document = deploy(runtime: 100.0, startup: 1.0)
    past = history(runtime: [ 100.0, 100.0, 100.0 ], startup: [ 1.0, 1.0, 1.0 ])

    assert_empty findings(document, past)
  end

  test "fewer than three comparable deploys is not a trend" do
    assert_empty findings(deploy(build: 84.0), history(build: [ 40.0, 41.0 ]))
  end

  test "only the same command counts, and only the runs that succeeded" do
    past = history(build: [ 40.0, 41.0, 42.0 ]).map { |document| document.merge(command: "redeploy") }
    assert_empty findings(deploy(build: 84.0), past)

    failed = history(build: [ 40.0, 41.0, 42.0 ]).map { |document| document.merge(status: "failed") }
    assert_empty findings(deploy(build: 84.0), failed)
  end

  test "at most the last five deploys are compared" do
    past = history(build: [ 40.0, 40.0, 40.0, 40.0, 40.0, 1000.0, 1000.0 ])
    finding = findings(deploy(build: 84.0), past).find { |f| f.rule == "trend-build" }

    assert_equal "build 84.0s vs median 40.0s over the last 5 deploys", finding.message
  end

  test "a phase this run never had is not compared against one it did" do
    document = deploy(runtime: 100.0)
    past = history(build: [ 40.0, 40.0, 40.0 ], runtime: [ 100.0, 100.0, 100.0 ])

    assert_empty findings(document, past).select { |f| f.rule == "trend-build" }
  end

  test "an ignored trend rule never reaches the advice block" do
    past = history(build: [ 40.0, 41.0, 42.0 ])

    assert_empty findings(deploy(build: 84.0), past, ignore: [ "trend-build" ])
  end

  private
    def findings(document, history, ignore: [])
      Dash::Report::Trends.new(document, history: history, ignore: ignore).findings
    end

    def deploy(runtime: 100.0, **phases)
      { command: "deploy", status: "succeeded", runtime: runtime, phases: phases_for(**phases) }
    end

    def history(runtime: [], **phases)
      count = [ runtime.size, *phases.values.map(&:size) ].max

      count.times.map do |i|
        deploy(runtime: runtime[i] || 100.0, **phases.transform_values { |values| values[i] }.compact)
      end
    end

    NAMES = { build: "Build and push app image", boot: "Boot", startup: "Startup (load, config)",
              validate: "Validate config and secrets" }.freeze

    def phases_for(**phases)
      phases.map { |key, seconds| { name: NAMES.fetch(key), depth: 0, seconds: seconds } }
    end
end
