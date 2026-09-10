# apt's recommended packages and its package lists both ship in the layer unless the same
# RUN gets rid of them. Only worth saying about a stage that ends up in the image.
class Dash::Dockerfile::Rules::AptHygiene < Dash::Dockerfile::Rules::Base
  NO_RECOMMENDS = /--no-install-recommends/
  LIST_CLEANUP = %r{rm\s+-rf\s+/var/lib/apt/lists}
  APT_OPERATION = /\bapt-get\s+(?:-\S+\s+)*(?:update|install|upgrade)\b/
  # One shell command at a time: a later, compliant install must not vouch for an
  # earlier one, and a cleanup only counts after the last thing that refilled the lists.
  SEGMENT = /&&|\|\||;/
  SUGGESTION = "add --no-install-recommends to every install and rm -rf /var/lib/apt/lists/* at the end of the same RUN"

  def findings
    document.shipped_stages.flat_map { |stage| stage.instructions }.filter_map do |instruction|
      next unless context.apt_install?(instruction)

      problems = problems_in(instruction.shell_command.split(SEGMENT))
      next if problems.empty?

      note at(instruction), "apt-get install #{problems.join(" and ")}", SUGGESTION
    end
  end

  private
    def problems_in(segments)
      installs = segments.select { |segment| segment.match?(Dash::Dockerfile::Context::APT_INSTALL.first) }
      last_apt = segments.rindex { |segment| segment.match?(APT_OPERATION) }
      cleaned = segments.drop(last_apt + 1).any? { |segment| segment.match?(LIST_CLEANUP) }

      problems = []
      problems << "installs recommended packages" if installs.any? { |segment| !segment.match?(NO_RECOMMENDS) }
      problems << "leaves /var/lib/apt/lists in the layer" unless cleaned
      problems
    end
end
