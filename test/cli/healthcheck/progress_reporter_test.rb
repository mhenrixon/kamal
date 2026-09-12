require_relative "../cli_test_case"

class CliHealthcheckProgressReporterTest < CliTestCase
  setup do
    DASH.configure config_file: Pathname.new(File.expand_path("test/fixtures/deploy_with_readiness_sources.yml")), destination: nil, version: "999"
  end

  test "a progress line becomes the beacon the client-side poll used to print" do
    output = stdouted { report "dash-readiness 4 26 starting\n" }

    assert_match "Container not ready yet, retrying in 1s (4s elapsed, 26s left)", output
  end

  # The SSH backend splits on packet boundaries, not newlines, so a line can arrive in
  # pieces - and a beacon printed for half a line would be wrong in both numbers.
  test "a line split across chunks is reported once, when it is whole" do
    reporter = Dash::Cli::Healthcheck::ProgressReporter.new

    partial = stdouted { reporter.on_data(nil, :stderr, "dash-readiness 4 2") }
    assert_equal "", partial

    completed = stdouted { reporter.on_data(nil, :stderr, "6 starting\ndash-readiness 5 25 starting\n") }
    assert_match "(4s elapsed, 26s left)", completed
    assert_match "(5s elapsed, 25s left)", completed
  end

  # The wait's stdout carries the final status and the host may say anything else on its
  # way past. Only the wait's own beacon is ours to reprint.
  test "anything that is not a progress line is ignored" do
    output = stdouted do
      report "healthy\n"
      report "Error response from daemon: No such container\n"
      report "dash-readiness not-a-number 26 starting\n"
    end

    assert_equal "", output
  end

  private
    def report(data)
      Dash::Cli::Healthcheck::ProgressReporter.new.on_data(nil, :stderr, data, nil)
    end
end
