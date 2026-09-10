# A parsed Dockerfile: its instructions in file order, grouped into stages.
#
# Named Document rather than File so that `File.fnmatch` inside Dash::Dockerfile still
# means the one in Ruby's core library.
class Dash::Dockerfile::Document
  attr_reader :instructions, :stages, :directives

  def initialize(instructions:, stages:, directives: {})
    @instructions = instructions
    @stages = stages
    @directives = directives
  end

  def shipped_stages
    stages.select(&:shipped?)
  end

  def final_stage
    stages.last
  end

  def each_instruction(name)
    return to_enum(:each_instruction, name) unless block_given?

    instructions.each { |instruction| yield instruction if instruction.name == name }
  end
end
