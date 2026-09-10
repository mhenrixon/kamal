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
    # The name and the content arrive together, always. A hard link publishes a file
    # that is already complete, atomically, and only if the name is free — so two runs
    # racing for one name (started_at is recorded to the second, and `safe` maps
    # `eu/west` and `eu-west` onto the same string) each keep their own report, and
    # there is never a moment where a report exists empty or half-written. That last
    # part matters more than it sounds: every reader skips a file it cannot parse, and
    # the prune only counts the files it could read, so anything left behind here would
    # stay in the directory forever.
    def publish(content)
      scratch = File.join(directory, ".#{base_name}.#{Process.pid}.tmp")
      File.write(scratch, content)

      begin
        linked(scratch)
      rescue SystemCallError
        created(scratch)
      end
    ensure
      File.delete(scratch) if scratch && File.exist?(scratch)
    end

    def linked(scratch)
      claim do |candidate|
        File.link(scratch, candidate)
        candidate
      rescue Errno::EEXIST
        nil
      end
    end

    # For a filesystem with no hard links. The name is claimed with an exclusive create —
    # which never replaces, so another run's report is safe — and the completed scratch
    # file is then renamed onto that placeholder, atomically, so no reader ever sees a
    # half-written report. The placeholder is the one thing that can be left behind
    # here, and it is the one thing nothing would ever clean up, so it comes down in an
    # `ensure`: a full disk and the operator's Ctrl-C (an Interrupt, not a
    # StandardError) both take the claimed name with them.
    def created(scratch)
      claim do |candidate|
        next unless placeholder?(candidate)

        filled(candidate, scratch)
      end
    end

    def placeholder?(candidate)
      File.open(candidate, File::WRONLY | File::CREAT | File::EXCL) { }
      true
    rescue Errno::EEXIST
      false
    end

    def filled(candidate, scratch)
      moved = false
      File.rename(scratch, candidate)
      moved = true

      candidate
    ensure
      File.delete(candidate) if !moved && File.exist?(candidate)
    end

    # Walks the candidate names until the block takes one, yielding nil for a name that
    # was already gone. Suffixed names sort after the one they collided with, which
    # Dash::Report::History#order_key relies on to read them back in run order.
    def claim
      suffix = 1
      candidate = File.join(directory, "#{base_name}.json")

      until (claimed = yield candidate)
        candidate = File.join(directory, "#{base_name}-#{suffix += 1}.json")
      end

      claimed
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
