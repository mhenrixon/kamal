# An unpinned base image makes a build unreproducible: the same Dockerfile builds a
# different image tomorrow, and nothing in the deploy says so.
class Dash::Dockerfile::Rules::LatestBase < Dash::Dockerfile::Rules::Base
  SUGGESTION = "pin a specific tag, or a digest for a build that must be reproducible"

  def findings
    document.stages.filter_map { |stage| finding_for(stage) }
  end

  private
    def finding_for(stage)
      return if built_on_another_stage?(stage) || stage.digest || stage.interpolated_tag?

      if stage.tag.nil?
        warning at(stage.instructions.first), "FROM #{stage.base} has no tag, so it resolves to :latest", SUGGESTION
      elsif stage.tag == "latest"
        warning at(stage.instructions.first), "FROM #{stage.base} is not pinned; the base image can change between builds", SUGGESTION
      end
    end

    def built_on_another_stage?(stage)
      document.stages.any? { |other| other.name == stage.base }
    end
end
