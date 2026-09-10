require "test_helper"

class DockerfileParserTest < ActiveSupport::TestCase
  test "instruction keywords are case insensitive and normalised" do
    document = parse("from alpine:3.20\nRun echo hi\n")

    assert_equal [ "FROM", "RUN" ], document.instructions.map(&:name)
  end

  test "comments and blank lines are skipped but still count towards line numbers" do
    document = parse("# a comment\n\nFROM alpine:3.20\n")

    assert_equal 1, document.instructions.size
    assert_equal 3, document.instructions.first.line
  end

  test "a backslash continuation joins into one instruction reported at its first line" do
    document = parse(<<~DOCKERFILE)
      FROM alpine:3.20
      RUN echo one && \\
          echo two
    DOCKERFILE

    run = document.instructions.last
    assert_equal "echo one && echo two", run.args
    assert_equal 2, run.line
  end

  test "an escape directive changes the continuation character" do
    document = parse("# escape=`\nFROM alpine:3.20\nRUN echo one && `\n    echo two\n")

    assert_equal "echo one && echo two", document.instructions.last.args
  end

  test "the syntax directive is captured and not parsed as an instruction" do
    document = parse("# syntax=docker/dockerfile:1\nFROM alpine:3.20\n")

    assert_equal "docker/dockerfile:1", document.directives["syntax"]
    assert_equal [ "FROM" ], document.instructions.map(&:name)
  end

  test "flags are separated from arguments" do
    document = parse(<<~DOCKERFILE)
      FROM alpine:3.20
      RUN --mount=type=cache,target=/root/.npm --network=none npm ci
      COPY --from=build --chown=app:app /rails /rails
    DOCKERFILE

    run, copy = document.instructions.last(2)

    assert_equal "npm ci", run.args
    assert_equal "type=cache,target=/root/.npm", run.flag("mount")
    assert_equal "none", run.flag("network")
    assert_equal "/rails /rails", copy.args
    assert_equal "build", copy.flag("from")
    assert_equal "app:app", copy.flag("chown")
  end

  test "repeated flags are all kept" do
    document = parse("FROM alpine\nRUN --mount=type=cache,target=/a --mount=type=secret,id=b true\n")

    assert_equal [ "type=cache,target=/a", "type=secret,id=b" ], document.instructions.last.flags["mount"]
  end

  test "a heredoc body becomes part of the instruction arguments" do
    document = parse(File.read("test/fixtures/dockerfiles/heredoc.Dockerfile"))

    run = document.instructions.find { |instruction| instruction.args.include?("apk add") }
    assert_includes run.args, "apk add --no-cache curl"
    assert_includes run.args, "echo done"
    assert_equal "RUN", run.name
  end

  test "a quoted heredoc delimiter terminates the body" do
    document = parse(File.read("test/fixtures/dockerfiles/heredoc.Dockerfile"))
    copy = document.instructions.find { |instruction| instruction.name == "COPY" }

    assert_includes copy.args, "listen = 8080"
    # The instruction after the heredoc is parsed as its own instruction, not swallowed.
    assert_equal 3, document.instructions.count { |instruction| instruction.name == "RUN" }
  end

  test "a comment between continuation lines is dropped from the command" do
    document = parse(File.read("test/fixtures/dockerfiles/heredoc.Dockerfile"))
    run = document.instructions.last

    assert_equal "echo one && echo two", run.args
  end

  test "the JSON array form is recognised and exposed as a shell command" do
    document = parse(File.read("test/fixtures/dockerfiles/heredoc.Dockerfile"))
    run = document.instructions.find { |instruction| instruction.args.start_with?("[") }

    assert_predicate run, :json?
    assert_equal [ "/bin/sh", "-c", "echo hello" ], run.argv
    assert_equal "/bin/sh -c echo hello", run.shell_command
  end

  test "stages are named, indexed and linked to their base" do
    document = parse(File.read("test/fixtures/dockerfiles/rails_multistage.Dockerfile"))

    assert_equal [ "base", "build", "stage-2" ], document.stages.map(&:name)
    assert_equal [ 0, 1, 2 ], document.stages.map(&:index)
    assert_equal [ "docker.io/library/ruby:$RUBY_VERSION-slim", "base", "base" ], document.stages.map(&:base)
  end

  test "an ARG before the first FROM belongs to no stage" do
    document = parse(File.read("test/fixtures/dockerfiles/rails_multistage.Dockerfile"))
    arg = document.instructions.first

    assert_equal "ARG", arg.name
    assert_nil arg.stage
    assert_equal "base", document.instructions[1].stage.name
  end

  test "the final stage and the stages it is built from are shipped" do
    document = parse(File.read("test/fixtures/dockerfiles/rails_multistage.Dockerfile"))

    assert_equal({ "base" => true, "build" => false, "stage-2" => true },
      document.stages.to_h { |stage| [ stage.name, stage.shipped? ] })
  end

  test "a single stage Dockerfile ships its only stage" do
    document = parse(File.read("test/fixtures/dockerfiles/naive_single_stage.Dockerfile"))

    assert_equal 1, document.stages.size
    assert_predicate document.stages.first, :shipped?
  end

  test "FROM tags, digests and AS names are pulled apart" do
    document = parse(<<~DOCKERFILE)
      FROM --platform=linux/amd64 ruby:3.4-slim AS base
      FROM alpine@sha256:abc123 AS pinned
      FROM busybox
    DOCKERFILE

    assert_equal [ "ruby", "alpine", "busybox" ], document.stages.map(&:image)
    assert_equal [ "3.4-slim", nil, nil ], document.stages.map(&:tag)
    assert_equal [ nil, "sha256:abc123", nil ], document.stages.map(&:digest)
    assert_equal "linux/amd64", document.stages.first.instructions.first.flag("platform")
  end

  test "an ARG interpolated tag is kept verbatim" do
    document = parse("ARG RUBY_VERSION=3.4\nFROM ruby:${RUBY_VERSION}-slim AS base\n")

    assert_equal "${RUBY_VERSION}-slim", document.stages.first.tag
    assert_predicate document.stages.first, :interpolated_tag?
  end

  test "a registry port is part of the image, not the tag" do
    document = parse("FROM localhost:5000/ubuntu\nFROM registry.example.com:443/team/app:1.2 AS b\n")

    assert_equal [ "localhost:5000/ubuntu", "registry.example.com:443/team/app" ], document.stages.map(&:image)
    assert_equal [ nil, "1.2" ], document.stages.map(&:tag)
  end

  test "an unterminated heredoc does not swallow the rest of the file" do
    document = parse("FROM alpine:3.20\nRUN printf '%s' '<<EOF'\nRUN echo still parsed\nUSER app\n")

    assert_equal [ "FROM", "RUN", "RUN", "USER" ], document.instructions.map(&:name)
    assert_equal "echo still parsed", document.instructions[2].args
  end

  test "a missing later delimiter leaves the earlier heredoc unconsumed too" do
    document = parse("FROM alpine:3.20\nCOPY <<A <<B /etc/\nfirst\nA\nsecond\nRUN echo parsed\n")

    # Nothing is consumed, so the would-be body lines parse as (nonsense) instructions of
    # their own — the point is that the RUN after them is still there to be analysed.
    assert_equal "<<A <<B /etc/", document.instructions[1].args
    assert_equal "echo parsed", document.instructions.last.args
  end

  test "only an explicit AS name can be inherited from" do
    document = parse("FROM alpine:3.20\nFROM stage-0\n")

    assert_equal [ false, true ], document.stages.map(&:shipped?)
  end

  test "an empty Dockerfile parses to nothing rather than raising" do
    document = parse("")

    assert_empty document.instructions
    assert_empty document.stages
  end

  private
    def parse(text)
      Dash::Dockerfile::Parser.parse(text)
    end
end
