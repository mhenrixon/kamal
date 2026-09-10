# Measured only: how many megabytes this build actually shipped to the builder before it
# ran a single instruction.
class Dash::Dockerfile::Rules::ContextSize < Dash::Dockerfile::Rules::Base
  THRESHOLD_BYTES = 50_000_000
  SUGGESTION = "trim the build context with .dockerignore, or point builder: context: at a smaller directory"

  def findings
    bytes = build&.context_bytes
    return [] if bytes.to_i <= THRESHOLD_BYTES

    [ warning("build context", "the build shipped #{Dash::Utils.human_bytes(bytes)}#{elapsed} of build context to the builder", SUGGESTION) ]
  end

  private
    # A build killed mid-transfer has a size but no duration; "in 0.0s" would be a
    # measurement nobody took.
    def elapsed
      format(" in %.1fs", build.context_seconds) if build.context_seconds
    end
end
