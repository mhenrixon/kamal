class Dash::Commands::Auditor < Dash::Commands::Base
  attr_reader :details
  delegate :escape_shell_value, to: Dash::Utils

  def initialize(config, **details)
    super(config)
    @details = details
  end

  # Runs remotely
  def record(line, **details)
    combine \
      ensure_run_directory,
      append([ :echo, escape_shell_value(audit_line(line, **details)) ], audit_log_file)
  end

  # The audit line and the action it describes in one round trip, still in that order:
  # the log is written first, and `&&` means a failed write aborts the action exactly as
  # a failed standalone audit would have.
  #
  # Only ever fold in commands the caller would `execute`. A `capture` folded in here
  # would come back with nothing to distinguish the audit's own output from the answer.
  def record_then(line, *commands, **details)
    combine record(line, **details), *commands
  end

  def reveal
    [ :tail, "-n", 50, audit_log_file ]
  end

  private
    def audit_log_file
      file = [ config.service, config.destination, "audit.log" ].compact.join("-")

      File.join(config.run_directory, file)
    end

    def audit_tags(**details)
      tags(**self.details, **details)
    end

    def audit_line(line, **details)
      "#{audit_tags(**details).except(:version, :service_version, :service)} #{line}"
    end
end
