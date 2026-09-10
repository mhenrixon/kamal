require "json"

# Reads the JSON reports every deploy leaves under `.dash/reports`.
#
# Entirely local and read-only: no lock, no SSH, nothing that can change a server. It is
# the command to reach for after a deploy has finished and the table has scrolled away,
# and the one that answers "was it always this slow?".
class Dash::Cli::Report < Dash::Cli::Base
  default_command :show

  TREND_HEADINGS = %w[ started version total build boot advice ].freeze
  COLUMNS = "  %-20s %-10s %8s %8s %8s  %s".freeze

  desc "show", "Print the last saved deploy report"
  option :last, type: :numeric, banner: "N", desc: "Print a trend table over the last N reports instead"
  def show
    if (last = options[:last])
      return say "--last takes a positive number of reports, got #{last}", :red unless count?(last)

      print_trend saved.recent(last.to_i)
    else
      print_latest saved.recent(1).first
    end
  end

  desc "path", "Print the directory saved reports are written to"
  def path
    puts reports_directory
  end

  private
    # Thor's :numeric happily hands over -1 or 2.5, which Array#first turns into a
    # backtrace. A typo in a flag deserves a sentence, not a stack trace.
    def count?(value)
      value.to_i == value && value.to_i > 0
    end

    def saved
      Dash::Report::History.new(reports_directory, destination: DASH.config.destination)
    end

    def print_latest(document)
      return say_nothing_saved unless document

      say "Deploy report for #{subject}", :magenta
      puts summary_line(document)
      puts Dash::Report.from_h(document).lines
    end

    def print_trend(documents)
      return say_nothing_saved if documents.empty?

      say "Last #{documents.size} #{"report".pluralize(documents.size)} for #{subject}", :magenta
      puts format(COLUMNS, *TREND_HEADINGS)
      documents.reverse_each { |document| puts trend_row(document) }
    end

    def subject
      [ DASH.config.service, ("to #{DASH.config.destination}" if DASH.config.destination) ].compact.join(" ")
    end

    def summary_line(document)
      "  #{document[:command]} #{document[:status]} in #{seconds(document[:runtime])} at #{document[:started_at]}" \
        "#{" (version #{document[:version]})" if document[:version]}#{error_note(document)}"
    end

    def error_note(document)
      " — #{document.dig(:error, :class)}: #{document.dig(:error, :message)}" if document[:error]
    end

    def trend_row(document)
      format COLUMNS, document[:started_at], (document[:version] || "").to_s[0...10],
        seconds(document[:runtime]), phase(document, Dash::Report::Trends::BUILD_PHASE),
        phase(document, Dash::Report::Trends::BOOT_PHASE), advice_count(document)
    end

    def phase(document, name)
      found = Array(document[:phases]).find { |candidate| candidate[:name] == name && candidate[:depth].to_i.zero? }

      found ? seconds(found[:seconds]) : "-"
    end

    def advice_count(document)
      findings = Array(document[:advice])
      warnings = findings.count { |finding| finding[:severity] == "warn" }

      "#{findings.size}#{" (#{warnings} warn)" if warnings > 0}"
    end

    def seconds(value)
      format("%.1fs", value.to_f)
    end

    def say_nothing_saved
      say "No saved reports for #{subject} in #{reports_directory}", :yellow
    end
end
