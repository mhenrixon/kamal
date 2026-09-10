require "test_helper"
require "time"

class ReportWriterTest < ActiveSupport::TestCase
  setup do
    @timings = Dash::Timings.new
    @report = Dash::Report.new(timings: @timings)
    @timings.record "Startup (load, config)", 1.0
  end

  test "writes the run under a timestamped name and returns the path" do
    in_reports_directory do |directory|
      path = write(directory: directory)

      assert_equal File.join(directory, "2026-09-10T12-00-00Z-default-deploy.json"), path
      assert_equal [ "deploy", "app", "succeeded" ], document(path).values_at(:command, :service, :status)
      assert_equal 1, document(path)[:schema]
      assert_equal 196.2, document(path)[:runtime]
    end
  end

  test "names the destination in the file so one project's histories stay apart" do
    in_reports_directory do |directory|
      path = write(directory: directory, destination: "production")

      assert_equal "2026-09-10T12-00-00Z-production-deploy.json", File.basename(path)
      assert_equal "production", document(path)[:destination]
    end
  end

  test "a destination that is not a filename does not become a path" do
    in_reports_directory do |directory|
      path = write(directory: directory, destination: "eu/west 1")

      assert_equal "2026-09-10T12-00-00Z-eu-west-1-deploy.json", File.basename(path)
      assert_equal "eu/west 1", document(path)[:destination]
    end
  end

  test "the reports directory keeps itself out of the operator's commits" do
    in_reports_directory do |directory|
      write(directory: directory)

      assert_equal "*\n!.gitignore\n", File.read(File.join(directory, ".gitignore"))
    end
  end

  test "an operator's own .gitignore is left alone" do
    in_reports_directory do |directory|
      FileUtils.mkdir_p directory
      File.write File.join(directory, ".gitignore"), "everything\n"

      write(directory: directory)

      assert_equal "everything\n", File.read(File.join(directory, ".gitignore"))
    end
  end

  test "a failed run is written with the error that ended it" do
    in_reports_directory do |directory|
      path = write(directory: directory, error: RuntimeError.new("boom"))

      assert_equal "failed", document(path)[:status]
      assert_equal({ class: "RuntimeError", message: "boom" }, document(path)[:error])
    end
  end

  test "history: 0 writes nothing at all" do
    in_reports_directory do |directory|
      assert_nil write(directory: directory, history: 0)
      assert_not File.exist?(directory)
    end
  end

  test "only the newest reports of this destination survive the prune" do
    in_reports_directory do |directory|
      6.times { |i| write(directory: directory, history: 3, started_at: Time.utc(2026, 9, 10, 12, 0, i)) }

      assert_equal %w[ 2026-09-10T12-00-03Z-default-deploy.json 2026-09-10T12-00-04Z-default-deploy.json
                       2026-09-10T12-00-05Z-default-deploy.json ], report_names(directory)
    end
  end

  test "pruning one destination leaves another destination's history standing" do
    in_reports_directory do |directory|
      3.times { |i| write(directory: directory, destination: "staging", started_at: Time.utc(2026, 9, 10, 12, 0, i)) }
      2.times { |i| write(directory: directory, history: 1, started_at: Time.utc(2026, 9, 10, 13, 0, i)) }

      assert_equal 4, report_names(directory).size
      assert_equal 1, report_names(directory).count { |name| name.include?("-default-") }
    end
  end

  # started_at is only recorded to the second, and two destinations that differ only in a
  # character a filename cannot hold sanitize to the same string. Neither run may lose its
  # report to the other.
  test "two runs that would share a name each keep their own file" do
    in_reports_directory do |directory|
      first = write(directory: directory)
      second = write(directory: directory)
      third = write(directory: directory, destination: "eu/west")
      fourth = write(directory: directory, destination: "eu-west")

      assert_equal 4, [ first, second, third, fourth ].uniq.size
      assert_equal "2026-09-10T12-00-00Z-default-deploy-2.json", File.basename(second)
      assert_equal [ nil, nil, "eu/west", "eu-west" ],
        [ first, second, third, fourth ].map { |path| document(path)[:destination] }
    end
  end

  # A deploy interrupted mid-write must not leave a truncated file behind: nothing ever
  # prunes one, because pruning only counts the reports it could read.
  test "the file appears whole or not at all" do
    in_reports_directory do |directory|
      seen = []
      Dash::Report::History.any_instance.stubs(:prune).with { seen = Dir.children(directory).sort; true }

      path = write(directory: directory)

      assert_equal [ ".gitignore", File.basename(path) ], seen
      assert_empty Dir.children(directory).grep_v(/\A\.gitignore\z|\.json\z/)
    end
  end

  # There is no "check, then take": the name is claimed with an exclusive create, so a
  # run that loses a race takes the next name rather than the other run's report — and
  # a file another process dropped in is never written over, whatever it holds.
  test "a name that is already taken is never written over" do
    in_reports_directory do |directory|
      FileUtils.mkdir_p directory
      File.write File.join(directory, "2026-09-10T12-00-00Z-default-deploy.json"), "theirs"
      File.write File.join(directory, "2026-09-10T12-00-00Z-default-deploy-2.json"), "also theirs"

      path = write(directory: directory)

      assert_equal "2026-09-10T12-00-00Z-default-deploy-3.json", File.basename(path)
      assert_equal "theirs", File.read(File.join(directory, "2026-09-10T12-00-00Z-default-deploy.json"))
      assert_equal "also theirs", File.read(File.join(directory, "2026-09-10T12-00-00Z-default-deploy-2.json"))
    end
  end

  test "a claim that cannot be filled is released rather than left as an empty report" do
    in_reports_directory do |directory|
      File.stubs(:rename).raises(Errno::EACCES, "reports")

      assert_raises(Errno::EACCES) { write(directory: directory) }
      assert_empty Dir.children(directory).grep(/\.json\z/)
    ensure
      File.unstub(:rename)
    end
  end

  test "no temporary file survives a write" do
    in_reports_directory do |directory|
      write(directory: directory)
      write(directory: directory)

      assert_empty Dir.children(directory).grep(/tmp/)
    end
  end

  # The unsuffixed name sorts after its `-2` sibling byte for byte, so a prune that
  # trusted the filename would keep the older run and delete the one just written.
  test "the prune keeps the run that collided its way to a suffix, not the one it collided with" do
    in_reports_directory do |directory|
      first = write(directory: directory, history: 1)
      second = write(directory: directory, history: 1)

      assert_not File.exist?(first)
      assert File.exist?(second)
    end
  end

  test "the phases, build and advice of the run all land in the document" do
    in_reports_directory do |directory|
      @timings.phase("Build and push app image") { |entry| @report.build_entry = entry }
      @report.build = Dash::Build::Report.new(steps: [ bundle_install_step ])
      @report.advice = [ Dash::Dockerfile::Finding.new(rule: "root-user", severity: :info, location: "Dockerfile:9", message: "no USER") ]

      document = document(write(directory: directory))

      assert_equal [ "Startup (load, config)", "Build and push app image" ], document[:phases].map { |phase| phase[:name] }
      assert_equal 1, document[:build_phase]
      assert_equal "RUN bundle install", document[:build][:steps].sole[:instruction]
      assert_equal "root-user", document[:advice].sole[:rule]
    end
  end

  # The writer and `dash report` have to agree: what was saved must render as the deploy
  # rendered it, or the command is reading a shape nothing writes.
  test "a saved report reads back as the same table" do
    in_reports_directory do |directory|
      @timings.phase("Build and push app image") { |entry| @report.build_entry = entry }
      @timings.phase("Boot") { }
      @report.build = Dash::Build::Report.new(steps: [ bundle_install_step ])
      @report.advice = [ Dash::Dockerfile::Finding.new(rule: "root-user", severity: :info, location: "Dockerfile:9", message: "no USER") ]

      assert_equal @report.lines, Dash::Report.from_h(document(write(directory: directory))).lines
    end
  end

  private
    def in_reports_directory
      Dir.mktmpdir { |tmpdir| yield File.join(tmpdir, ".dash", "reports") }
    end

    def write(directory:, history: 20, destination: nil, error: nil, started_at: Time.utc(2026, 9, 10, 12, 0, 0))
      Dash::Report::Writer.new(@report, run: run_for(destination, error, started_at), keep: history, directory: directory).write
    end

    def run_for(destination, error, started_at)
      {
        command: "deploy", service: "app", destination: destination, version: "abc123",
        started_at: started_at.utc.iso8601, runtime: 196.2,
        status: error ? "failed" : "succeeded",
        error: error && { class: error.class.name, message: error.message }
      }.compact
    end

    def document(path)
      JSON.parse(File.read(path), symbolize_names: true)
    end

    def report_names(directory)
      Dir.children(directory).grep(/\.json\z/).sort
    end

    def bundle_install_step
      Dash::Build::Step.new(1, kind: :instruction).tap do |step|
        step.instruction = "RUN bundle install"
        step.stage, step.ordinal, step.steps_in_stage = "build", 1, 5
        step.seconds = 84.1
      end
    end
end
