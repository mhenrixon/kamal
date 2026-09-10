require "test_helper"

class DockerfileHadolintTest < ActiveSupport::TestCase
  OUTPUT = [
    { code: "DL3008", level: "warning", line: 7, message: "Pin versions in apt get install" },
    { code: "DL3002", level: "error", line: 9, message: "Last USER should not be root" }
  ].to_json

  test "no findings when hadolint is not on PATH" do
    Dash::Dockerfile::Hadolint.stubs(:available?).returns(false)
    Open3.expects(:capture2).never

    assert_empty findings
  end

  test "issues map to findings with the code as the rule id" do
    stub_hadolint OUTPUT

    assert_equal [
      [ "DL3008", :info, "Dockerfile:7", "DL3008: Pin versions in apt get install" ],
      [ "DL3002", :warn, "Dockerfile:9", "DL3002: Last USER should not be root" ]
    ], findings.map { |finding| [ finding.rule, finding.severity, finding.location, finding.message ] }
  end

  test "unparsable output is reported as such, not as a failure to run" do
    stub_hadolint "not json at all"

    assert_equal [ "hadolint" ], findings.map(&:rule)
    assert_match "hadolint output could not be parsed", findings.first.message
  end

  test "valid JSON that is not a list is reported as unparsable, not as a failure to run" do
    stub_hadolint "{}"

    assert_match "hadolint output could not be parsed (expected a JSON array, got hash)", findings.first.message
  end

  test "blank output means no findings" do
    stub_hadolint ""

    assert_empty findings
  end

  test "the resolved file is what runs, the display path is what prints" do
    Dash::Dockerfile::Hadolint.stubs(:available?).returns(true)
    status = mock("status")
    status.stubs(:success?).returns(true)
    Open3.expects(:capture2).with("hadolint", "--format", "json", "--no-fail", "/abs/Dockerfile").returns([ OUTPUT, status ])

    assert_equal "Dockerfile:7", Dash::Dockerfile::Hadolint.new(path: "Dockerfile", file: "/abs/Dockerfile").findings.first.location
  end

  test "a non-zero exit becomes one informational finding" do
    stub_hadolint "", success: false

    assert_match "hadolint could not run (exited 1)", findings.first.message
  end

  test "PATH is searched without a shell" do
    # test_helper pins availability off for the whole suite so a developer with hadolint
    # installed sees the same advice CI does. This is the one test that asks the real
    # question, so it takes the pin out.
    Dash::Dockerfile::Hadolint.unstub(:available?)

    Dir.mktmpdir do |dir|
      executable = File.join(dir, "hadolint")
      File.write(executable, "#!/bin/sh\n")
      File.chmod(0o755, executable)

      with_path("#{dir}#{File::PATH_SEPARATOR}/nonexistent dir; rm -rf /") do
        assert_predicate Dash::Dockerfile::Hadolint, :available?
      end

      with_path("/nonexistent") { assert_not Dash::Dockerfile::Hadolint.available? }
    end
  end

  private
    def findings
      Dash::Dockerfile::Hadolint.new(path: "Dockerfile").findings
    end

    def stub_hadolint(output, success: true)
      Dash::Dockerfile::Hadolint.stubs(:available?).returns(true)
      status = mock("status")
      status.stubs(:success?).returns(success)
      status.stubs(:exitstatus).returns(success ? 0 : 1)
      Open3.stubs(:capture2).returns([ output, status ])
    end

    def with_path(path)
      original = ENV["PATH"]
      ENV["PATH"] = path
      yield
    ensure
      ENV["PATH"] = original
    end
end
