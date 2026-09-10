require "json"
require "open3"
require "active_support/core_ext/string/filters"

# Optional supplement to the built-in rules: whatever `hadolint` has to say about the same
# file, when the operator already has it installed.
#
# Run as a plain local process rather than through SSHKit, so the command sequence a deploy
# prints — and the cost-guard test that pins it — is unchanged. `--no-fail` keeps its exit
# status out of the deploy, and anything that goes wrong becomes one informational finding
# rather than an exception.
class Dash::Dockerfile::Hadolint
  EXECUTABLE = "hadolint".freeze
  # hadolint's own levels. `error` is the only one worth a warning next to a deploy; the
  # rest are style notes that should not compete with a measured finding.
  SEVERITIES = { "error" => :warn }.freeze

  class << self
    # No shell: PATH is walked directly, so a directory with a space or a semicolon in it
    # cannot turn a lookup into a command.
    def available?
      ENV["PATH"].to_s.split(::File::PATH_SEPARATOR).any? do |directory|
        path = ::File.join(directory, EXECUTABLE)
        ::File.executable?(path) && !::File.directory?(path)
      end
    end
  end

  def initialize(path:, file: path)
    @path = path
    @file = file
  end

  def findings
    return [] unless self.class.available?

    output, status = Open3.capture2(EXECUTABLE, "--format", "json", "--no-fail", @file)
    return unavailable("exited #{status.exitstatus}") unless status.success?
    return [] if output.strip.empty?

    JSON.parse(output).map { |issue| finding_for(issue) }
  rescue JSON::ParserError, TypeError, NoMethodError => e
    # It ran; what it printed is what dash could not read. Different problem, different line.
    note("hadolint output could not be parsed (#{e.message.truncate(80)})")
  rescue StandardError => e
    unavailable(e.message)
  end

  private
    def finding_for(issue)
      Dash::Dockerfile::Finding.new \
        rule: issue["code"],
        severity: SEVERITIES.fetch(issue["level"], :info),
        location: "#{@path}:#{issue["line"]}",
        message: "#{issue["code"]}: #{issue["message"]}",
        suggestion: nil
    end

    def unavailable(reason)
      note "hadolint could not run (#{reason})"
    end

    def note(message)
      [ Dash::Dockerfile::Finding.new(rule: "hadolint", severity: :info, location: EXECUTABLE,
        message: message, suggestion: "silence this with report: hadolint: false") ]
    end
end
