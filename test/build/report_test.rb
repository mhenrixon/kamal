require "test_helper"

class BuildReportTest < ActiveSupport::TestCase
  test "an empty report has nothing to say" do
    report = Dash::Build::Report.new

    assert_not report.any?
    assert_empty report.dockerfile_steps
    assert_nil report.context_bytes
    assert_equal 0.0, report.total_step_seconds
    assert_equal 0.0, report.export_seconds
    assert_empty report.slowest(5)
  end

  test "only vertices with an ordinal count as the operator's steps" do
    report = Dash::Build::Report.new(steps: [ internal, instruction(1, 4.0), instruction(2, 1.0, cached: true) ])

    assert_equal 2, report.dockerfile_steps.size
    assert_equal 1, report.cached_steps.size
    assert_equal 1, report.uncached_steps.size
    assert_equal 2, report.to_h[:total_steps]
  end

  test "the slowest steps skip cached ones and come back longest first" do
    steps = [ instruction(1, 4.0), instruction(2, 90.0, cached: true), instruction(3, 9.0), instruction(4, 1.0) ]

    assert_equal [ 9.0, 4.0 ], Dash::Build::Report.new(steps: steps).slowest(2).map(&:seconds)
  end

  test "export, cache export and push are separate numbers" do
    report = Dash::Build::Report.new(steps: [ vertex(:export, 12.0), vertex(:cache_export, 29.4) ], push_seconds: 8.0)

    assert_equal 12.0, report.export_seconds
    assert_equal 29.4, report.cache_export_seconds
    assert_equal 8.0, report.push_seconds
  end

  test "a step that never reported DONE contributes no seconds" do
    report = Dash::Build::Report.new(steps: [ instruction(1, nil), instruction(2, 3.0) ])

    assert_equal 3.0, report.total_step_seconds
    assert_equal [ 3.0, nil ], report.slowest(2).map(&:seconds)
  end

  test "errors are the steps that reported one" do
    broken = instruction(2, nil)
    broken.error = "process \"/bin/sh -c bundle install\" did not complete successfully: exit code: 1"

    assert_equal [ broken ], Dash::Build::Report.new(steps: [ instruction(1, 1.0), broken ]).errors
  end

  test "a cache-import miss is an error but not a failed step" do
    miss = vertex(:other, nil)
    miss.error = "failed to configure registry cache importer: registry.example.com/app-cache:latest: not found"
    broken = instruction(1, nil)
    broken.error = "did not complete successfully: exit code: 1"
    report = Dash::Build::Report.new(steps: [ miss, broken ])

    assert_equal [ miss, broken ], report.errors
    assert_equal [ broken ], report.failed_steps
  end

  test "to_h carries every step and the summary numbers" do
    report = Dash::Build::Report.new(steps: [ context(25_180_000, 0.2), instruction(1, 4.0) ], push_seconds: 1.0)

    assert_equal 25_180_000, report.to_h[:context_bytes]
    assert_equal 0.2, report.to_h[:context_seconds]
    assert_equal 1.0, report.to_h[:push_seconds]
    assert_equal 2, report.to_h[:steps].size
    assert_equal "[build 1/5] RUN step 1", report.to_h[:steps].last[:label]
  end

  test "from_h rebuilds the steps a saved report exported" do
    report = Dash::Build::Report.new(steps: [ context(25_180_000, 0.2), instruction(1, 4.0, cached: true), internal ], push_seconds: 1.0)

    assert_equal report.to_h, Dash::Build::Report.from_h(report.to_h).to_h
  end

  test "from_h survives the string keys and string kinds a JSON round trip leaves behind" do
    report = Dash::Build::Report.new(steps: [ instruction(1, 4.0) ], push_seconds: 1.0)

    rebuilt = Dash::Build::Report.from_h(JSON.parse(JSON.generate(report.to_h)))

    assert_equal "[build 1/5] RUN step 1", rebuilt.steps.sole.label
    assert_equal :instruction, rebuilt.steps.sole.kind
    assert_equal 1.0, rebuilt.push_seconds
    assert_equal 1, rebuilt.dockerfile_steps.size
  end

  private
    def instruction(ordinal, seconds, cached: false)
      Dash::Build::Step.new(ordinal, kind: :instruction).tap do |step|
        step.stage = "build"
        step.ordinal = ordinal
        step.steps_in_stage = 5
        step.instruction = "RUN step #{ordinal}"
        step.seconds = seconds
        step.cached = cached
      end
    end

    def internal
      Dash::Build::Step.new(99, kind: :metadata, name: "[internal] load metadata for ruby:3.3-slim")
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
