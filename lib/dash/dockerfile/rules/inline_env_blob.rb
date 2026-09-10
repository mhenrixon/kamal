# A wall of inline assignments in front of a command means editing any one value
# invalidates the layer — and makes the instruction unreadable in the bargain.
class Dash::Dockerfile::Rules::InlineEnvBlob < Dash::Dockerfile::Rules::Base
  ASSIGNMENT = /\A[A-Za-z_]\w*=\S*\s+/
  THRESHOLD = 20
  SUGGESTION = "move them to ARGs or an env file so editing one value does not rebuild the layer"

  def findings
    document.instructions.filter_map do |instruction|
      next unless instruction.name == "RUN"
      next unless (count = leading_assignments(instruction.shell_command.dup)) > THRESHOLD

      note at(instruction), "#{count} inline environment assignments precede the command", SUGGESTION
    end
  end

  private
    def leading_assignments(command)
      count = 0
      count += 1 while command.sub!(ASSIGNMENT, "")
      count
    end
end
