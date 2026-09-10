# A .dockerignore that misses the obvious offenders. .git is always worth naming; the
# rest only when the directory actually exists in the context.
class Dash::Dockerfile::Rules::DockerignoreGaps < Dash::Dockerfile::Rules::Base
  ALWAYS = ".git".freeze
  WHEN_PRESENT = %w[ node_modules tmp storage coverage log .env* ].freeze
  SUGGESTION = "add them to .dockerignore so they are not sent to the builder"

  def findings
    return [] if dockerignore.nil?
    return [] if (gaps = gaps()).empty?

    [ finding(severity, Dash::Dockerfile::Dockerignore::FILENAME, message(gaps), SUGGESTION) ]
  end

  private
    def gaps
      candidates = [ ALWAYS, *WHEN_PRESENT.flat_map { |name| context.context_entries(name) } ]
      candidates.uniq.reject { |name| dockerignore.covers?(name) }
    end

    # A context big enough to be worth seconds of every build turns the same gap from a
    # tidiness note into something that is costing the operator time.
    def severity
      big_context? ? :warn : :info
    end

    def message(gaps)
      measured = " — the measured build context was #{Dash::Utils.human_bytes(build.context_bytes)}" if big_context?

      "the build context ships #{gaps.join(", ")}#{measured}"
    end

    def big_context?
      build&.context_bytes.to_i > Dash::Dockerfile::Rules::ContextSize::THRESHOLD_BYTES
    end
end
