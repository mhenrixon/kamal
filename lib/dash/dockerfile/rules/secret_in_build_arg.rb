# Build args and ENV values are readable in the image history forever. A secret that has
# to be present at build time belongs in a mount that leaves no layer behind.
class Dash::Dockerfile::Rules::SecretInBuildArg < Dash::Dockerfile::Rules::Base
  SECRETISH = /(PASSWORD|SECRET|TOKEN|_KEY)\b/i
  # Rails' own placeholder: it exists precisely so no real key is needed at build time.
  ALLOWED = %w[ SECRET_KEY_BASE_DUMMY ].freeze
  SUGGESTION = "pass it with --mount=type=secret and list it under builder: secrets: in deploy.yml"

  def findings
    document.instructions.flat_map do |instruction|
      next [] unless %w[ ARG ENV ].include?(instruction.name)

      names(instruction).filter_map do |name|
        next if ALLOWED.include?(name) || !name.match?(SECRETISH)

        warning at(instruction), "#{instruction.name} #{name} bakes a secret into the image history", SUGGESTION
      end
    end
  end

  private
    def names(instruction)
      assigned = instruction.args.scan(/(?:\A|\s)([A-Za-z_]\w*)=/).flatten
      assigned.any? ? assigned : Array(instruction.args.split(/\s+/).first)
    end
end
