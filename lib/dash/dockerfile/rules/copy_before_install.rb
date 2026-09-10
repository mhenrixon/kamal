# The single most expensive Dockerfile mistake: copying the whole tree before installing
# dependencies, so every commit — a README typo included — reinstalls them.
class Dash::Dockerfile::Rules::CopyBeforeInstall < Dash::Dockerfile::Rules::Base
  SUGGESTION = "copy the dependency manifests first (Gemfile, package.json, lockfiles), install, then copy the rest of the tree"

  def findings
    document.stages.filter_map { |stage| finding_for(stage) }
  end

  private
    def finding_for(stage)
      copy = stage.instructions.find { |instruction| context.broad_copy?(instruction) } or return
      install = stage.instructions.find do |instruction|
        instruction.line > copy.line && context.dependency_install?(instruction)
      end
      return unless install

      warning at(copy), message(copy, install), SUGGESTION
    end

    def message(copy, install)
      [ "#{copy.name} #{copy.args} runs before `#{context.install_command(install)}` (line #{install.line}), ",
        "so dependencies reinstall on every commit", measured(install) ].compact.join
    end

    # Only when the build that just ran proves it: a cached install step costs nothing,
    # and advice that names a number nobody measured is worse than advice that doesn't.
    def measured(install)
      step = context.build_step_for(install)
      return if step.nil? || step.cached || step.seconds.to_f.zero?

      format(" (measured %.1fs uncached)", step.seconds)
    end
end
