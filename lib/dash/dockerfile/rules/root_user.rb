# A container with no USER runs as root, and so does anything that gets a shell in it.
class Dash::Dockerfile::Rules::RootUser < Dash::Dockerfile::Rules::Base
  SUGGESTION = "create a non-root user and add a USER line before the entrypoint"

  def findings
    stage = document.final_stage or return []
    return [] if stage.instructions.any? { |instruction| instruction.name == "USER" }

    [ note(at(stage.instructions.first), "the final stage has no USER, so the container runs as root", SUGGESTION) ]
  end
end
