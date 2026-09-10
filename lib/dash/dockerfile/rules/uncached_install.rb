# Measured only: a dependency install that missed the cache and cost real time, where no
# broad copy above it explains why. Something else invalidated the layer, and the operator
# is the only one who can say what.
class Dash::Dockerfile::Rules::UncachedInstall < Dash::Dockerfile::Rules::Base
  THRESHOLD_SECONDS = 10
  SUGGESTION = "check what changed above it — a COPY, an ARG, or a base image that moved"

  def findings
    return [] unless build

    document.instructions.filter_map do |instruction|
      next unless context.dependency_install?(instruction) && !context.busted_by_broad_copy?(instruction)

      step = context.build_step_for(instruction)
      next if step.nil? || step.cached || step.seconds.to_f <= THRESHOLD_SECONDS

      note at(instruction), format("`%s` ran %.1fs uncached", context.install_command(instruction), step.seconds), SUGGESTION
    end
  end
end
