# An ARG that changes on every commit — a git SHA, a build timestamp — invalidates every
# layer from its first use onwards. Referenced after the dependency install it costs
# nothing; referenced before it, it costs the whole install.
class Dash::Dockerfile::Rules::CacheBustingArg < Dash::Dockerfile::Rules::Base
  CACHE_BUSTING = /\A(?:.*_)?(?:GIT_SHA|COMMIT|SHA|BUILD_DATE|BUILD_TIME|BUILDTIME|VERSION)\z/i
  # RUBY_VERSION, NODE_VERSION and friends name a toolchain and change once a quarter.
  TOOLCHAIN = /_VERSION\z/i
  SUGGESTION = "reference it after the dependency install, so a new commit does not invalidate it"

  def findings
    document.each_instruction("ARG").filter_map { |arg| finding_for(arg) }
  end

  private
    def finding_for(arg)
      name = arg.args.split("=").first.to_s
      return unless name.match?(CACHE_BUSTING) && !name.match?(TOOLCHAIN)

      stage = arg.stage || document.stages.first or return
      barrier = last_install_line(stage) or return
      reference = reference_before(name, arg.line, barrier)
      return unless reference

      note at(arg), "ARG #{name} changes on every commit and is referenced on line #{reference.line}, before the dependency install on line #{barrier}", SUGGESTION
    end

    def last_install_line(stage)
      stage.instructions.select { |instruction| context.dependency_install?(instruction) }.last&.line
    end

    def reference_before(name, from_line, barrier)
      document.instructions.find do |instruction|
        instruction.line > from_line && instruction.line < barrier && instruction.to_s.match?(/\$\{?#{Regexp.escape(name)}\}?/)
      end
    end
end
