require "test_helper"

class ConfigurationReportTest < ActiveSupport::TestCase
  test "defaults with no report key at all" do
    report = config.report

    assert report.advice?
    assert_equal "auto", report.hadolint
    assert report.hadolint?
    assert_equal 20, report.history
    assert_empty report.ignore
  end

  test "advice can be turned off" do
    assert_not config(advice: false).report.advice?
  end

  test "hadolint can be disabled" do
    report = config(hadolint: false).report

    assert_not report.hadolint?
    assert_equal false, report.hadolint
  end

  test "history bounds how many reports are kept" do
    assert_equal 0, config(history: 0).report.history
  end

  test "ignored rule ids are stringified" do
    assert_equal [ "root-user", "DL3008" ], config(ignore: [ "root-user", "DL3008" ]).report.ignore
  end

  test "to_h round-trips what was configured" do
    assert_equal({ "advice" => false, "history" => 5 }, config(advice: false, history: 5).report.to_h)
  end

  test "an unknown key is rejected" do
    error = assert_raises(Dash::ConfigurationError) { config(nonsense: true) }

    assert_match "report: unknown key: nonsense", error.message
  end

  test "a wrong type is rejected" do
    error = assert_raises(Dash::ConfigurationError) { config(history: "lots") }

    assert_match "report/history", error.message
  end

  private
    def config(**report)
      deploy = {
        service: "app", image: "dhh/app",
        registry: { "username" => "dhh", "password" => "secret" },
        builder: { "arch" => "amd64" },
        servers: [ "1.1.1.1" ]
      }
      deploy[:report] = report.transform_keys(&:to_s) if report.any?

      Dash::Configuration.new(deploy)
    end
end
