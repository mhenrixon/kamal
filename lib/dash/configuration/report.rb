# The `report:` block: how much of the deploy report to print, and how much of it to keep.
#
# Every key is optional and the defaults are what an operator who has never heard of the
# block gets — the table always prints, the advice under it prints, and hadolint joins in
# only if they already have it installed.
class Dash::Configuration::Report
  include Dash::Configuration::Validation

  DEFAULT_HISTORY = 20
  HADOLINT_AUTO = "auto".freeze

  attr_reader :report_config

  def initialize(config:)
    @report_config = config.raw_config.report || {}
    validate! @report_config unless @report_config.empty?
  end

  def advice?
    report_config.fetch("advice", true)
  end

  def hadolint
    report_config.fetch("hadolint", HADOLINT_AUTO)
  end

  # "auto" means run it when it is on PATH — the availability check itself lives in
  # Dash::Dockerfile::Hadolint, because only it knows what running costs.
  def hadolint?
    hadolint.to_s == HADOLINT_AUTO
  end

  def history
    report_config.fetch("history", DEFAULT_HISTORY).to_i
  end

  def ignore
    Array(report_config["ignore"]).map(&:to_s)
  end

  def to_h
    report_config
  end
end
