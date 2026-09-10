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
    # `ENV KEY value` (legacy form) declares exactly one name, whatever the value holds;
    # `ENV A=1 B=2` and `ARG NAME[=default]` declare one per assignment.
    def names(instruction)
      first = instruction.args.split(/\s+/).first.to_s
      return [ first ] unless first.include?("=")

      instruction.args.scan(/(?:\A|\s)([A-Za-z_]\w*)=/).flatten
    end
end
