# Piping a download straight into a shell runs whatever the server sends today, and there
# is no version in the Dockerfile to say what that was.
class Dash::Dockerfile::Rules::CurlPipeShell < Dash::Dockerfile::Rules::Base
  PIPE_TO_SHELL = /\b(?:curl|wget)\b[^|]*\|\s*(?:sudo\s+)?(?:ba|z|k)?sh\b/
  SUGGESTION = "download to a file, verify a checksum, then run it — and pin the version"

  def findings
    document.instructions.filter_map do |instruction|
      next unless instruction.name == "RUN" && instruction.shell_command.match?(PIPE_TO_SHELL)

      note at(instruction), "a download is piped straight into a shell, so the build runs unverified code", SUGGESTION
    end
  end
end
