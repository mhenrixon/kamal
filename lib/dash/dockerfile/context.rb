# Everything a rule is allowed to look at: the parsed Dockerfile, the build context on
# disk, the builder's configuration, and — when the advice is printed next to a build
# that actually ran — what that build measured.
#
# The shared predicates live here rather than in each rule so that "what counts as a
# dependency install" has one answer, and so the measured half of a rule can find the
# buildx vertex that corresponds to a Dockerfile line.
class Dash::Dockerfile::Context
  # The package managers whose install step is worth protecting from cache busting, and
  # the cache directory each conventionally wants mounted.
  DEPENDENCY_INSTALLS = [
    [ /\bbundle\s+(?:_[\d._]+_\s+)?install\b/, "/usr/local/bundle/cache" ],
    [ /\bnpm\s+(?:ci|install)\b/, "/root/.npm" ],
    [ /\byarn\s+install\b/, "/usr/local/share/.cache/yarn" ],
    [ /\bpnpm\s+install\b/, "/root/.local/share/pnpm/store" ],
    [ /\bbun\s+install\b/, "/root/.bun/install/cache" ],
    [ /\bpip3?\s+install\b/, "/root/.cache/pip" ],
    [ /\bpoetry\s+install\b/, "/root/.cache/pypoetry" ],
    [ /\bgo\s+mod\s+download\b/, "/go/pkg/mod" ],
    [ /\bcargo\s+(?:build|fetch)\b/, "/usr/local/cargo/registry" ],
    [ /\bcomposer\s+install\b/, "/root/.composer/cache" ],
    [ /\bmix\s+deps\.get\b/, "/root/.hex" ],
    [ /\bdotnet\s+restore\b/, "/root/.nuget/packages" ]
  ].freeze

  # apt takes its options before or after the verb (`apt-get -y install`,
  # `apt-get -t bookworm-backports install`), so the verb is found past any of them.
  APT_OPTIONS = /(?:-\S+(?:\s+[^-\s]\S*)?\s+)*/
  APT_INSTALL = [ /\bapt-get\s+#{APT_OPTIONS.source}install\b/, "/var/cache/apt" ].freeze

  # A copy that ships the whole tree, so every commit invalidates it and everything
  # layered on top of it.
  BROAD_SOURCES = [ ".", "./", "*", "/" ].freeze

  # buildx expands ARG and ENV references in the vertex name it prints, so a step's text
  # and the Dockerfile line it came from stop agreeing at the first ${…}. Match on the
  # longest shared prefix instead, and require enough of it that two unrelated RUNs
  # cannot be confused for each other.
  MINIMUM_STEP_MATCH = 12

  attr_reader :document, :context_dir, :dockerignore, :build, :builder, :path

  def initialize(document:, context_dir: nil, dockerignore: nil, build: nil, builder: nil, path: "Dockerfile")
    @document = document
    @context_dir = context_dir
    @dockerignore = dockerignore
    @build = build
    @builder = builder
    @path = path
  end

  def location_for(instruction)
    "#{path}:#{instruction.line}"
  end

  def dependency_install?(instruction)
    !install_match(instruction).nil?
  end

  # The command that made it a dependency install ("bundle install"), for advice that
  # names what the operator wrote rather than the whole RUN.
  def install_command(instruction)
    install_match(instruction)&.first
  end

  def install_cache_target(instruction)
    install_match(instruction)&.last
  end

  def apt_install?(instruction)
    instruction.name == "RUN" && instruction.shell_command.match?(APT_INSTALL.first)
  end

  def broad_copy?(instruction)
    return false unless %w[ COPY ADD ].include?(instruction.name)
    return false if instruction.flag?("from")

    sources(instruction).any? { |source| BROAD_SOURCES.include?(source) }
  end

  # A dependency install directly after a broad copy is invalidated by every commit,
  # which is a finding of its own — rules that would otherwise report the same slow step
  # twice defer to it.
  def busted_by_broad_copy?(instruction)
    stage = instruction.stage or return false

    stage.instructions.any? { |other| other.line < instruction.line && broad_copy?(other) }
  end

  # buildx labels a step with its stage name except in a single-stage build, where it
  # prints none. A multi-platform build reports the same step once per platform; the
  # slowest one is the number worth quoting.
  def build_step_for(instruction)
    return unless build

    text = normalize(instruction.to_s)
    candidates = build.instruction_steps.select { |step| same_stage?(step, instruction) }

    best = candidates.max_by do |step|
      matched = normalize(step.instruction)
      [ matched == text ? 1 : 0, shared_prefix(text, matched), step.seconds.to_f ]
    end
    return unless best

    matched = normalize(best.instruction)
    best if matched == text || shared_prefix(text, matched) >= MINIMUM_STEP_MATCH
  end

  def context_entries(name)
    return [] unless context_dir

    Dir.glob(name, base: context_dir, flags: ::File::FNM_DOTMATCH)
  end

  private
    def install_match(instruction)
      return unless instruction.name == "RUN"

      command = instruction.shell_command
      DEPENDENCY_INSTALLS.each do |pattern, target|
        matched = command[pattern]
        return [ matched, target ] if matched
      end
      nil
    end

    def same_stage?(step, instruction)
      step.stage.nil? ? document.stages.one? : step.stage == instruction.stage&.name
    end

    def sources(instruction)
      words = instruction.json? ? instruction.argv : instruction.args.split(/\s+/)
      words.size > 1 ? words[0..-2] : words
    end

    def normalize(text)
      text.to_s.squeeze(" ").strip
    end

    def shared_prefix(one, other)
      length = 0
      length += 1 while length < one.length && length < other.length && one[length] == other[length]
      length
    end
end
