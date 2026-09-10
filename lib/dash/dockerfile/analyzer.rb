# Runs the rule set over a parsed Dockerfile and returns the advice.
#
# Rules that need measurements (`build:`) stay silent without them, so the same analyzer
# serves `dash doctor` — static, no build, no SSH — and the block printed under a deploy,
# where the numbers upgrade a static hint into "this cost you 84.1 seconds".
class Dash::Dockerfile::Analyzer
  RULES = [
    Dash::Dockerfile::Rules::CopyBeforeInstall,
    Dash::Dockerfile::Rules::ContextSize,
    Dash::Dockerfile::Rules::MissingDockerignore,
    Dash::Dockerfile::Rules::DockerignoreGaps,
    Dash::Dockerfile::Rules::LatestBase,
    Dash::Dockerfile::Rules::SecretInBuildArg,
    Dash::Dockerfile::Rules::SingleStageBuildDeps,
    Dash::Dockerfile::Rules::AptHygiene,
    Dash::Dockerfile::Rules::CacheBustingArg,
    Dash::Dockerfile::Rules::CacheExportCost,
    Dash::Dockerfile::Rules::CurlPipeShell,
    Dash::Dockerfile::Rules::InlineEnvBlob,
    Dash::Dockerfile::Rules::NoCacheMount,
    Dash::Dockerfile::Rules::UncachedInstall,
    Dash::Dockerfile::Rules::RootUser
  ].freeze

  # Reads and parses the file. Missing is the caller's problem to report: `dash doctor`
  # fails the check, a deploy stays quiet (a --skip-push deploy has no Dockerfile and no
  # business complaining about it).
  def self.for_file(path, **options)
    new document: Dash::Dockerfile::Parser.parse(File.read(path)), path: path, file: path, **options
  end

  # `path` is what findings print (the operator's own `builder: dockerfile:`); `file` is
  # where the file actually is, for the one rule that has to open it again.
  def initialize(document:, context_dir: nil, build: nil, builder: nil, path: "Dockerfile", file: path, ignore: [], hadolint: false)
    # A context that is not a local directory (a git URL, or a clone that has not been
    # prepared yet) is not something the .dockerignore rules can say anything about.
    directory = context_dir if context_dir && File.directory?(context_dir)

    @context = Dash::Dockerfile::Context.new \
      document: document, context_dir: directory, dockerignore: (Dash::Dockerfile::Dockerignore.in(directory) if directory),
      build: build, builder: builder, path: path
    @file = file
    @ignore = Array(ignore).map(&:to_s)
    @hadolint = hadolint
  end

  # Warnings first, then the informational findings, each group in rule order — an
  # operator reading the block top down sees what is costing them before what is merely
  # worth knowing.
  def findings
    (rule_findings + hadolint_findings)
      .reject { |finding| @ignore.include?(finding.rule) }
      .sort_by.with_index { |finding, index| [ finding.warn? ? 0 : 1, index ] }
  end

  private
    def rule_findings
      RULES.flat_map { |rule| rule.new(@context).findings }
    end

    def hadolint_findings
      return [] unless @hadolint

      Dash::Dockerfile::Hadolint.new(path: @context.path, file: @file).findings
    end
end
