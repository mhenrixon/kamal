require "fileutils"
require "json"

# Writes one JSON report per run under `.dash/reports`, so the next deploy has something
# to compare itself against and CI has something to archive.
#
# A failed deploy is written too, with whatever was measured before it broke: the run an
# operator most wants to look at afterwards is the one that went wrong.
class Dash::Report::Writer
  GITIGNORE = "*\n!.gitignore\n".freeze

  # A destination is an operator-supplied string and a command can carry a subcommand, so
  # neither is trusted to be a filename.
  UNSAFE = /[^\w.-]+/

  attr_reader :report, :run, :keep, :directory

  # `run` is the metadata Dash::Cli::Base assembled for this invocation — the same hash
  # the trend rules compared against, so the file and the advice cannot disagree.
  def initialize(report, run:, keep:, directory: Dash::ProjectDirectory.join("reports"))
    @report = report
    @run = run
    @keep = keep
    @directory = directory
  end

  # Returns the path it wrote, or nil when the operator turned history off.
  def write
    return if keep.zero?

    prepare_directory
    @path = publish JSON.pretty_generate(report.to_h(**run))
    Dash::Report::History.new(directory, destination: run[:destination]).prune(keep)

    @path
  end

  private
    # Written under a private temporary name, then linked into place under the first free
    # public one. The link is the check and the claim in one step: it never replaces, so
    # two runs racing for the same name — started_at is recorded to the second, and
    # `safe` maps `eu/west` and `eu-west` onto the same string — cannot write over each
    # other, and a deploy interrupted mid-write leaves a stray temporary file rather than
    # a truncated report that nothing would ever prune.
    def publish(content)
      scratch = File.join(directory, ".#{base_name}.#{Process.pid}.tmp")
      File.write(scratch, content)

      claim(scratch)
    ensure
      File.delete(scratch) if scratch && File.exist?(scratch)
    end

    def claim(scratch)
      suffix = 1
      candidate = File.join(directory, "#{base_name}.json")

      begin
        File.link(scratch, candidate)
      rescue Errno::EEXIST
        candidate = File.join(directory, "#{base_name}-#{suffix += 1}.json")
        retry
      rescue SystemCallError
        # A filesystem without hard links (some network mounts). Rename is not
        # no-replace, but it is still atomic, and a report beats no report.
        File.rename(scratch, candidate)
      end

      candidate
    end

    def base_name
      "#{timestamp}-#{safe(destination)}-#{safe(run[:command])}"
    end

    # The started_at the report already carries, with the colons a filename cannot have.
    def timestamp
      safe(run[:started_at].to_s.tr(":", "-"))
    end

    def destination
      run[:destination].presence || "default"
    end

    def safe(part)
      part.to_s.gsub(UNSAFE, "-")
    end

    # The .gitignore is written next to the reports rather than left to the operator: a
    # project that commits `.dash/` would otherwise start committing a deploy report on
    # every deploy, and nobody asked for that in their diff.
    def prepare_directory
      FileUtils.mkdir_p(directory)
      gitignore = File.join(directory, ".gitignore")
      File.write(gitignore, GITIGNORE) unless File.exist?(gitignore)
    end
end
