require "test_helper"

class ReportHistoryTest < ActiveSupport::TestCase
  test "reports come back newest first" do
    in_history do |directory|
      save directory, "2026-09-10T12-00-00Z-default-deploy.json", runtime: 100.0
      save directory, "2026-09-11T12-00-00Z-default-deploy.json", runtime: 200.0

      assert_equal [ 200.0, 100.0 ], history(directory).recent(5).map { |document| document[:runtime] }
    end
  end

  test "recent takes at most the count asked for" do
    in_history do |directory|
      3.times { |i| save directory, "2026-09-1#{i}T12-00-00Z-default-deploy.json" }

      assert_equal 2, history(directory).recent(2).size
    end
  end

  test "a destination only ever sees its own deploys" do
    in_history do |directory|
      save directory, "2026-09-10T12-00-00Z-staging-deploy.json", destination: "staging"
      save directory, "2026-09-10T13-00-00Z-production-deploy.json", destination: "production"

      assert_equal [ "production" ], history(directory, destination: "production").recent(5).map { |d| d[:destination] }
      assert_empty history(directory).recent(5)
    end
  end

  test "a report with no destination belongs to the default history" do
    in_history do |directory|
      save directory, "2026-09-10T12-00-00Z-default-deploy.json"

      assert_equal 1, history(directory).recent(5).size
    end
  end

  # The directory is the operator's: a deploy killed mid-write, a file dropped in by
  # hand, or a report from a dash that writes schema 2 must all cost nothing.
  test "unreadable, foreign and future-schema files are skipped in silence" do
    in_history do |directory|
      FileUtils.mkdir_p directory
      File.write File.join(directory, "half-written.json"), '{"schema": 1, "phas'
      File.write File.join(directory, "notes.txt"), "not a report at all"
      File.write File.join(directory, "schema-2.json"), JSON.generate(schema: 2, destination: nil)
      File.write File.join(directory, "an-array.json"), JSON.generate([ 1, 2 ])
      save directory, "2026-09-10T12-00-00Z-default-deploy.json"

      assert_equal 1, history(directory).recent(5).size
    end
  end

  # A file can be valid JSON, claim schema 1, and still be nothing dash wrote. Rendering
  # it would crash `dash report` on a document the operator hand-edited.
  test "a schema-1 document of the wrong shape is skipped like an unreadable one" do
    in_history do |directory|
      FileUtils.mkdir_p directory
      write directory, "phases-not-a-list.json", schema: 1, destination: nil, phases: "nope"
      write directory, "phases-not-hashes.json", schema: 1, destination: nil, phases: [ "nope" ]
      write directory, "advice-not-a-list.json", schema: 1, destination: nil, phases: [], advice: "nope"
      write directory, "build-not-a-hash.json", schema: 1, destination: nil, phases: [], build: "nope"
      save directory, "2026-09-10T12-00-00Z-default-deploy.json"

      assert_equal 1, history(directory).recent(5).size
    end
  end

  # Fields the writer always sets, in shapes it never writes. `Array(nil)` would render
  # a missing phases list as an empty table, `build: false` would simply be ignored, and
  # `error: "boom"` reaches nothing until `dash report` tries to dig into it.
  test "a document missing a field the writer always sets is skipped" do
    in_history do |directory|
      FileUtils.mkdir_p directory
      write directory, "phases-nil.json", schema: 1, destination: nil, phases: nil
      write directory, "build-false.json", schema: 1, destination: nil, phases: [], build: false
      write directory, "error-a-string.json", schema: 1, destination: nil, phases: [], error: "boom"
      save directory, "2026-09-10T12-00-00Z-default-deploy.json"

      assert_equal 1, history(directory).recent(5).size
    end
  end

  test "a document whose fields are the right shape but the wrong type is skipped too" do
    in_history do |directory|
      FileUtils.mkdir_p directory
      write directory, "seconds-not-a-number.json", schema: 1, destination: nil, phases: [ { name: "Boot", seconds: {} } ]
      write directory, "step-seconds-not-a-number.json", schema: 1, destination: nil, phases: [],
        build: { steps: [ { number: 1, kind: "instruction", ordinal: 1, seconds: {} } ] }
      write directory, "severity-not-a-string.json", schema: 1, destination: nil, phases: [], advice: [ { severity: {} } ]
      write directory, "runtime-not-a-number.json", schema: 1, destination: nil, phases: [], runtime: {}
      save directory, "2026-09-10T12-00-00Z-default-deploy.json"

      assert_equal 1, history(directory).recent(5).size
    end
  end

  # Two runs in the same second get `X.json` and `X-2.json`; byte for byte the first
  # sorts last, which would make the older run "newest".
  test "a collision suffix orders after the name it collided with" do
    in_history do |directory|
      save directory, "2026-09-10T12-00-00Z-default-deploy.json", runtime: 1.0
      save directory, "2026-09-10T12-00-00Z-default-deploy-2.json", runtime: 2.0
      save directory, "2026-09-10T12-00-00Z-default-deploy-10.json", runtime: 10.0
      save directory, "2026-09-09T12-00-00Z-default-deploy.json", runtime: 0.5

      assert_equal [ 10.0, 2.0, 1.0, 0.5 ], history(directory).recent(5).map { |document| document[:runtime] }
    end
  end

  test "a document with no phases at all is still a document" do
    in_history do |directory|
      FileUtils.mkdir_p directory
      write directory, "bare.json", schema: 1, destination: nil, phases: []

      assert_equal 1, history(directory).recent(5).size
    end
  end

  test "an empty or missing directory simply has no history" do
    in_history do |directory|
      assert_not history(directory).any?
      assert_empty history(directory).recent(5)
    end
  end

  test "prune keeps the newest and deletes the rest of this destination" do
    in_history do |directory|
      5.times { |i| save directory, "2026-09-1#{i}T12-00-00Z-default-deploy.json" }

      history(directory).prune(2)

      assert_equal %w[ 2026-09-13T12-00-00Z-default-deploy.json 2026-09-14T12-00-00Z-default-deploy.json ],
        Dir.children(directory).sort
    end
  end

  test "prune leaves other destinations and unreadable files where they are" do
    in_history do |directory|
      save directory, "2026-09-10T12-00-00Z-staging-deploy.json", destination: "staging"
      File.write File.join(directory, "half-written.json"), "{"
      3.times { |i| save directory, "2026-09-1#{i}T13-00-00Z-default-deploy.json" }

      history(directory).prune(1)

      assert_equal %w[ 2026-09-12T13-00-00Z-default-deploy.json half-written.json
                       2026-09-10T12-00-00Z-staging-deploy.json ].sort, Dir.children(directory).sort
    end
  end

  private
    def in_history
      Dir.mktmpdir { |tmpdir| yield File.join(tmpdir, "reports") }
    end

    def history(directory, destination: nil)
      Dash::Report::History.new(directory, destination: destination)
    end

    def write(directory, name, **document)
      File.write File.join(directory, name), JSON.generate(document)
    end

    def save(directory, name, destination: nil, runtime: 100.0)
      FileUtils.mkdir_p directory
      File.write File.join(directory, name),
        JSON.generate(schema: Dash::Report::SCHEMA, command: "deploy", destination: destination,
          status: "succeeded", runtime: runtime, phases: [], advice: [])
    end
end
