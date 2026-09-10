# Compilers and header packages installed in the only stage ship to production: a bigger
# image, a bigger attack surface, and nothing gained once the gems are built.
class Dash::Dockerfile::Rules::SingleStageBuildDeps < Dash::Dockerfile::Rules::Base
  # `(?=\s|$)` rather than `\b`: `+` is not a word character, so `g++\b` never matches.
  BUILD_PACKAGES = /\b(build-essential|gcc|g\+\+|make|[\w.+-]+-dev)(?=\s|$)/
  SUGGESTION = "split into a build stage and a runtime stage, and COPY --from the build output"

  def findings
    return [] unless document.stages.one?

    document.stages.first.instructions.filter_map do |instruction|
      next unless instruction.name == "RUN"
      next unless (packages = instruction.shell_command.scan(BUILD_PACKAGES).map(&:first)).any?

      warning at(instruction), "the only stage installs build tooling (#{packages.uniq.join(", ")}), which ships in the image", SUGGESTION
    end
  end
end
