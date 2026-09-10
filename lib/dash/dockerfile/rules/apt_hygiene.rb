# apt's recommended packages and its package lists both ship in the layer unless the same
# RUN gets rid of them. Only worth saying about a stage that ends up in the image.
class Dash::Dockerfile::Rules::AptHygiene < Dash::Dockerfile::Rules::Base
  NO_RECOMMENDS = /--no-install-recommends/
  LIST_CLEANUP = %r{rm\s+-rf\s+/var/lib/apt/lists}
  SUGGESTION = "add --no-install-recommends and rm -rf /var/lib/apt/lists/* to the same RUN"

  def findings
    document.shipped_stages.flat_map { |stage| stage.instructions }.filter_map do |instruction|
      next unless context.apt_install?(instruction)

      command = instruction.shell_command
      problems = []
      problems << "installs recommended packages" unless command.match?(NO_RECOMMENDS)
      problems << "leaves /var/lib/apt/lists in the layer" unless command.match?(LIST_CLEANUP)
      next if problems.empty?

      note at(instruction), "apt-get install #{problems.join(" and ")}", SUGGESTION
    end
  end
end
