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
        created(content)
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

    # For a filesystem with no hard links, where the alternative would be a rename —
    # and a rename replaces, which would put the overwriting back on exactly the mounts
    # least likely to be tested. An exclusive create claims the name, and the content
    # goes in through the same descriptor, so nothing else can take the name and no
    # empty file is ever visible. A write that fails takes the name back down with it.
    def created(content)
      claim do |candidate|
        File.open(candidate, File::WRONLY | File::CREAT | File::EXCL) { |file| file.write(content) }
        candidate
      rescue Errno::EEXIST
        nil
      rescue StandardError
        File.delete(candidate) if File.exist?(candidate)
        raise
      end
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
