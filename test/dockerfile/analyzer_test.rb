require "test_helper"

class DockerfileAnalyzerTest < ActiveSupport::TestCase
  CONTEXT_DIR = "test/fixtures/dockerfiles/context"

  test "a well-formed multi-stage Dockerfile has nothing to say" do
    assert_empty analyze("rails_multistage").map(&:rule)
  end

  test "every static rule fires on a naive single stage Dockerfile" do
    rules = analyze("naive_single_stage").map(&:rule)

    assert_equal %w[
      copy-before-install latest-base secret-in-build-arg single-stage-build-deps
      apt-hygiene cache-busting-arg curl-pipe-shell inline-env-blob no-cache-mount root-user
    ].sort, rules.uniq.sort
  end

  test "warnings sort above the informational findings" do
    severities = analyze("naive_single_stage").map(&:severity)

    assert_equal severities.sort_by { |severity| severity == :warn ? 0 : 1 }, severities
  end

  test "copy-before-install names the copy that busts the install" do
    finding = find("naive_single_stage", "copy-before-install")

    assert_equal :warn, finding.severity
    assert_equal "Dockerfile:5", finding.location
    assert_equal "COPY . . runs before `bundle install` (line 15), so dependencies reinstall on every commit", finding.message
    assert_match "copy the dependency manifests first", finding.suggestion
  end

  test "copy-before-install appends the measured cost when the build measured that step" do
    build = build_report(step("RUN bundle install", stage: "stage-0", seconds: 84.1))
    finding = find("naive_single_stage", "copy-before-install", build: build)

    assert_match "(measured 84.1s uncached)", finding.message
  end

  test "a cached install step adds no measured note" do
    build = build_report(step("RUN bundle install", stage: "stage-0", seconds: 0.0, cached: true))

    assert_no_match(/measured/, find("naive_single_stage", "copy-before-install", build: build).message)
  end

  test "latest-base flags an untagged or :latest base image" do
    findings = analyze_text("FROM ruby:latest\nFROM busybox AS b\nFROM ruby:3.4-slim AS c\n").select { |f| f.rule == "latest-base" }

    assert_equal [ "Dockerfile:1", "Dockerfile:2" ], findings.map(&:location)
  end

  test "latest-base accepts a digest and an interpolated tag" do
    findings = analyze_text("ARG V=3.4\nFROM ruby:$V AS a\nFROM alpine@sha256:abc AS b\nFROM a\n")

    assert_empty findings.select { |finding| finding.rule == "latest-base" }
  end

  test "apt-hygiene only looks at stages that ship" do
    text = <<~DOCKERFILE
      FROM ruby:3.4 AS build
      RUN apt-get install -y git
      FROM ruby:3.4
      COPY --from=build /app /app
    DOCKERFILE

    assert_empty analyze_text(text).select { |finding| finding.rule == "apt-hygiene" }
  end

  test "root-user looks at the shipped final stage only" do
    text = <<~DOCKERFILE
      FROM ruby:3.4 AS build
      USER app
      FROM ruby:3.4
      COPY --from=build /app /app
    DOCKERFILE

    assert_equal [ "root-user" ], analyze_text(text).map(&:rule)
  end

  test "secret-in-build-arg lets the dummy key through" do
    text = "FROM ruby:3.4\nENV SECRET_KEY_BASE_DUMMY=1\nARG API_TOKEN\n"
    findings = analyze_text(text).select { |finding| finding.rule == "secret-in-build-arg" }

    assert_equal [ "Dockerfile:3" ], findings.map(&:location)
  end

  test "cache-busting-arg ignores toolchain version args and unreferenced ones" do
    text = <<~DOCKERFILE
      FROM ruby:3.4
      ARG RUBY_VERSION
      ARG BUILD_DATE
      ARG UNUSED_SHA
      ENV STAMP=$BUILD_DATE
      RUN bundle install
    DOCKERFILE
    findings = analyze_text(text).select { |finding| finding.rule == "cache-busting-arg" }

    assert_equal [ "Dockerfile:3" ], findings.map(&:location)
  end

  test "cache-busting-arg stays quiet when the reference comes after the install" do
    text = "FROM ruby:3.4\nARG BUILD_DATE\nRUN bundle install\nENV STAMP=$BUILD_DATE\n"

    assert_empty analyze_text(text).select { |finding| finding.rule == "cache-busting-arg" }
  end

  test "missing-dockerignore fires when the context has none" do
    Dir.mktmpdir do |dir|
      findings = analyze_text("FROM ruby:3.4\n", context_dir: dir)

      assert_equal [ ".dockerignore" ], findings.select { |f| f.rule == "missing-dockerignore" }.map(&:location)
    end
  end

  test "dockerignore-gaps names the directories the context ships anyway" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".dockerignore"), "log\n")
      FileUtils.mkdir_p File.join(dir, "node_modules")
      FileUtils.mkdir_p File.join(dir, "log")

      finding = analyze_text("FROM ruby:3.4\n", context_dir: dir).find { |f| f.rule == "dockerignore-gaps" }

      assert_equal :info, finding.severity
      assert_match ".git", finding.message
      assert_match "node_modules", finding.message
      assert_no_match(/\blog\b/, finding.message)
    end
  end

  test "a big measured context turns the dockerignore gap into a warning" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".dockerignore"), "log\n")
      build = build_report(context_step(bytes: 356_515_840, seconds: 3.2))

      finding = analyze_text("FROM ruby:3.4\n", context_dir: dir, build: build).find { |f| f.rule == "dockerignore-gaps" }

      assert_equal :warn, finding.severity
      assert_match "356.5MB", finding.message
    end
  end

  test "context-size reports a large measured context on its own" do
    build = build_report(context_step(bytes: 356_515_840, seconds: 3.2))
    finding = analyze_text("FROM ruby:3.4\n", context_dir: CONTEXT_DIR, build: build).find { |f| f.rule == "context-size" }

    assert_equal :warn, finding.severity
    assert_equal "build context", finding.location
    assert_match "356.5MB in 3.2s", finding.message
  end

  test "context-size stays quiet under the threshold" do
    build = build_report(context_step(bytes: 1_000_000, seconds: 0.1))

    assert_empty analyze_text("FROM ruby:3.4\n", context_dir: CONTEXT_DIR, build: build).select { |f| f.rule == "context-size" }
  end

  test "cache-export-cost needs both a measured export and mode=max" do
    build = build_report(step("RUN bundle install", seconds: 100.0), cache_export: 29.4)

    finding = analyze_text("FROM ruby:3.4\n", build: build, builder: builder(cache_to: "type=registry,ref=x,mode=max"))
      .find { |f| f.rule == "cache-export-cost" }
    assert_match "29.4s of 129.4s", finding.message
    assert_match "mode=min", finding.suggestion

    assert_empty analyze_text("FROM ruby:3.4\n", build: build, builder: builder(cache_to: "type=registry,ref=x"))
      .select { |f| f.rule == "cache-export-cost" }
  end

  test "uncached-install names a slow install no broad copy explains" do
    text = "FROM ruby:3.4\nCOPY Gemfile ./\nRUN bundle install\n"
    build = build_report(step("RUN bundle install", stage: "stage-0", seconds: 84.1))

    finding = analyze_text(text, build: build).find { |f| f.rule == "uncached-install" }
    assert_match "84.1s uncached", finding.message
  end

  test "uncached-install defers to copy-before-install when a broad copy explains it" do
    build = build_report(step("RUN bundle install", stage: "stage-0", seconds: 84.1))

    assert_empty analyze("naive_single_stage", build: build).select { |f| f.rule == "uncached-install" }
  end

  test "latest-base skips scratch and warns on an explicit :latest behind an interpolated registry" do
    findings = analyze_text("ARG REGISTRY\nFROM scratch AS a\nFROM $REGISTRY/ubuntu:latest AS b\nFROM $IMAGE AS c\nFROM localhost:5000/app AS d\n")
      .select { |f| f.rule == "latest-base" }

    assert_equal [ "Dockerfile:3", "Dockerfile:5" ], findings.map(&:location)
  end

  test "single-stage-build-deps recognises g++" do
    findings = analyze_text("FROM ruby:3.4\nRUN apt-get install -y g++\n").select { |f| f.rule == "single-stage-build-deps" }

    assert_match "g++", findings.sole.message
  end

  test "apt rules see apt-get's global option form" do
    rules = analyze_text("FROM ruby:3.4\nRUN apt-get -y install git\n").map(&:rule)

    assert_includes rules, "apt-hygiene"
    assert_includes rules, "no-cache-mount"
  end

  test "apt-hygiene checks every install in a RUN and the order of the cleanup" do
    hidden = "FROM ruby:3.4\nRUN apt-get install -y git && apt-get install --no-install-recommends -y curl && rm -rf /var/lib/apt/lists/*\n"
    early = "FROM ruby:3.4\nRUN rm -rf /var/lib/apt/lists/* && apt-get install --no-install-recommends -y git\n"
    clean = "FROM ruby:3.4\nRUN apt-get update && apt-get install --no-install-recommends -y git && rm -rf /var/lib/apt/lists/*\n"

    assert_match "recommended packages", analyze_text(hidden).find { |f| f.rule == "apt-hygiene" }.message
    assert_match "leaves /var/lib/apt/lists", analyze_text(early).find { |f| f.rule == "apt-hygiene" }.message
    assert_empty analyze_text(clean).select { |f| f.rule == "apt-hygiene" }
  end

  test "a JSON-form COPY of the tree is a broad copy" do
    text = "FROM ruby:3.4\nCOPY [\".\", \"/app\"]\nRUN bundle install\n"

    assert_includes analyze_text(text).map(&:rule), "copy-before-install"
  end

  test "dockerignore patterns may carry a ./ prefix" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".dockerignore"), "./.git\n")

      assert_empty analyze_text("FROM ruby:3.4\n", context_dir: dir).select { |f| f.rule == "dockerignore-gaps" }
    end
  end

  test "cache-busting-arg needs the whole name, not a prefix, and ignores FROM" do
    prefix = "FROM ruby:3.4\nARG COMMIT\nARG COMMIT_SHA\nENV X=$COMMIT_SHA\nRUN bundle install\n"
    from = "ARG COMMIT\nFROM app:$COMMIT\nRUN bundle install\n"

    assert_equal [ "Dockerfile:3" ], analyze_text(prefix).select { |f| f.rule == "cache-busting-arg" }.map(&:location)
    assert_empty analyze_text(from).select { |f| f.rule == "cache-busting-arg" }
  end

  test "secret-in-build-arg reads the legacy ENV form" do
    findings = analyze_text("FROM ruby:3.4\nENV API_TOKEN a=b\nENV SAFE x=y\n").select { |f| f.rule == "secret-in-build-arg" }

    assert_equal [ "Dockerfile:2" ], findings.map(&:location)
  end

  test "cache-export-cost reads the mode option exactly" do
    build = build_report(step("RUN bundle install", seconds: 100.0), cache_export: 29.4)

    assert_empty analyze_text("FROM ruby:3.4\n", build: build, builder: builder(cache_to: "type=registry,ref=x,scope=mode=max"))
      .select { |f| f.rule == "cache-export-cost" }
  end

  test "a short instruction still matches its build step exactly" do
    build = build_report(step("RUN npm ci", stage: "stage-0", seconds: 40.0))
    finding = analyze_text("FROM node:22\nCOPY package.json ./\nRUN npm ci\n", build: build).find { |f| f.rule == "uncached-install" }

    assert_match "40.0s uncached", finding.message
  end

  test "a single-stage build's steps carry no stage name and still match" do
    build = build_report(step("RUN bundle install", stage: nil, seconds: 84.1))

    assert_match "measured 84.1s", find("naive_single_stage", "copy-before-install", build: build).message
  end

  test "inline-env-blob counts assignments with quoted values" do
    assignments = (1..21).map { |i| "K#{i}=\"a b\"" }.join(" ")

    assert_includes analyze_text("FROM ruby:3.4\nRUN #{assignments} ./bin/setup\n").map(&:rule), "inline-env-blob"
  end

  test "curl-pipe-shell sees sudo flags and process substitution" do
    text = "FROM ruby:3.4\nRUN curl -fsSL x | sudo -E bash\nRUN bash <(curl -fsSL y)\n"

    assert_equal [ "Dockerfile:2", "Dockerfile:3" ], analyze_text(text).select { |f| f.rule == "curl-pipe-shell" }.map(&:location)
  end

  test "apt rules see an option that takes a value before the verb" do
    rules = analyze_text("FROM ruby:3.4\nRUN apt-get -t bookworm-backports install git\n").map(&:rule)

    assert_includes rules, "apt-hygiene"
    assert_includes rules, "no-cache-mount"
  end

  test "apt-hygiene reads each line of a heredoc RUN as its own command" do
    text = "FROM ruby:3.4\nRUN <<EOF\napt-get update\napt-get install --no-install-recommends -y git\nrm -rf /var/lib/apt/lists/*\nEOF\n"

    assert_empty analyze_text(text).select { |f| f.rule == "apt-hygiene" }
  end

  test "single-stage-build-deps sees a package followed by a shell separator" do
    assert_includes analyze_text("FROM ruby:3.4\nRUN apt-get install -y gcc; true\n").map(&:rule), "single-stage-build-deps"
  end

  test "curl-pipe-shell sees sudo options with arguments" do
    assert_includes analyze_text("FROM ruby:3.4\nRUN curl -fsSL x | sudo -u root bash\n").map(&:rule), "curl-pipe-shell"
  end

  test "an exact build step wins over a longer one that shares its prefix" do
    text = "FROM ruby:3.4\nCOPY Gemfile ./\nRUN bundle install\n"
    build = build_report(step("RUN bundle install --jobs 4", stage: "stage-0", seconds: 200.0),
                         step("RUN bundle install", stage: "stage-0", seconds: 30.0))

    assert_match "30.0s uncached", analyze_text(text, build: build).find { |f| f.rule == "uncached-install" }.message
  end

  test "ignored rule ids are dropped" do
    rules = analyze("naive_single_stage", ignore: %w[ root-user latest-base ]).map(&:rule)

    assert_not_includes rules, "root-user"
    assert_not_includes rules, "latest-base"
    assert_includes rules, "copy-before-install"
  end

  test "hadolint findings join the rest when it is enabled and available" do
    Dash::Dockerfile::Hadolint.any_instance.stubs(:findings).returns([
      Dash::Dockerfile::Finding.new(rule: "DL3008", severity: :info, location: "Dockerfile:7", message: "DL3008: pin versions", suggestion: nil)
    ])

    rules = analyze("naive_single_stage", hadolint: "auto").map(&:rule)

    assert_includes rules, "DL3008"
  end

  test "hadolint is not consulted when it is disabled" do
    Dash::Dockerfile::Hadolint.any_instance.expects(:findings).never

    analyze("naive_single_stage", hadolint: false)
  end

  private
    def analyze(fixture, **options)
      analyze_text File.read("test/fixtures/dockerfiles/#{fixture}.Dockerfile"), **options
    end

    def analyze_text(text, context_dir: CONTEXT_DIR, **options)
      Dash::Dockerfile::Analyzer.new(
        document: Dash::Dockerfile::Parser.parse(text), context_dir: context_dir, **options
      ).findings
    end

    def find(fixture, rule, **options)
      analyze(fixture, **options).find { |finding| finding.rule == rule } ||
        flunk("no #{rule} finding in #{analyze(fixture, **options).map(&:rule).inspect}")
    end

    def builder(cache_to:)
      Struct.new(:cache_to).new(cache_to)
    end

    def build_report(*steps, cache_export: 0.0)
      steps += [ vertex(:cache_export, cache_export) ] if cache_export > 0
      Dash::Build::Report.new(steps: steps)
    end

    def step(instruction, stage: "stage-0", seconds: 1.0, cached: false)
      Dash::Build::Step.new(1, kind: :instruction).tap do |step|
        step.instruction = instruction
        step.stage = stage
        step.ordinal = 1
        step.steps_in_stage = 1
        step.seconds = seconds
        step.cached = cached
      end
    end

    def context_step(bytes:, seconds:)
      Dash::Build::Step.new(2, kind: :context, name: "[internal] load build context").tap do |step|
        step.bytes = bytes
        step.seconds = seconds
      end
    end

    def vertex(kind, seconds)
      Dash::Build::Step.new(3, kind: kind, name: kind.to_s).tap { |step| step.seconds = seconds }
    end
end
