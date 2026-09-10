# A final stage that sets no USER runs as whatever its base image left it as — root, for
# nearly every official image — and so does anything that gets a shell in it.
class Dash::Dockerfile::Rules::RootUser < Dash::Dockerfile::Rules::Base
  SUGGESTION = "create a non-root user and add a USER line before the entrypoint, unless the base image already switched"

  def findings
    stage = document.final_stage or return []
    return [] if stage.instructions.any? { |instruction| instruction.name == "USER" }

    [ note(at(stage.instructions.first), "the final stage sets no USER, so the container runs as whatever the base image does — usually root", SUGGESTION) ]
  end
end
