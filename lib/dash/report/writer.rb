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
    write_atomically JSON.pretty_generate(report.to_h(**run))
    Dash::Report::History.new(directory, destination: run[:destination]).prune(keep)

    path
  end

  private
    # started_at is recorded to the second, and `safe` maps `eu/west` and `eu-west` onto
    # the same component — so the obvious name is not guaranteed to be free. Take the next
    # one rather than write over a run that already happened.
    def path
      @path ||= free_path
    end

    def free_path
      candidate = File.join(directory, "#{base_name}.json")
      suffix = 1

      candidate = File.join(directory, "#{base_name}-#{suffix += 1}.json") while File.exist?(candidate)

      candidate
    end

    def base_name
      "#{timestamp}-#{safe(destination)}-#{safe(run[:command])}"
    end

    # Written under a temporary name and moved into place, so a deploy interrupted
    # mid-write leaves nothing behind. A truncated report would be skipped by every
    # reader — including the prune, which only counts the files it could read — and would
    # sit in the directory forever.
    def write_atomically(content)
      scratch = "#{path}.tmp"

      File.write(scratch, content)
      File.rename(scratch, path)
    ensure
      File.delete(scratch) if scratch && File.exist?(scratch)
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
