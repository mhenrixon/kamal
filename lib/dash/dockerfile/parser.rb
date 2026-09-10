# Turns Dockerfile text into instructions and stages.
#
# Line-oriented, because that is how BuildKit reads it: a physical line is joined to the
# next while it ends in the escape character, comment lines in between are dropped, and a
# heredoc redirection pulls the following lines in verbatim until its delimiter.
#
# It is deliberately forgiving. Advice is a courtesy printed next to a deploy, so a file
# this parser cannot make sense of must produce fewer findings, never an exception — the
# authority on whether a Dockerfile builds is BuildKit, not this.
class Dash::Dockerfile::Parser
  DIRECTIVE = /\A#\s*(?<name>syntax|escape)\s*=\s*(?<value>\S+)\s*\z/i
  COMMENT = /\A\s*#/
  BLANK = /\A\s*\z/
  INSTRUCTION = /\A\s*(?<name>[A-Za-z]+)(?:\s+(?<rest>.*))?\z/m
  FLAG = /\A--(?<key>[a-zA-Z][\w-]*)=(?<value>(?:"[^"]*"|'[^']*'|\S)*)\s*/
  # `<<EOF`, `<<-EOF`, `<<"EOF"`, `<<'EOF'` — the quoted forms only change how BuildKit
  # expands the body, not where it ends.
  HEREDOC = /<<-?\s*(?<quote>["']?)(?<delimiter>[A-Za-z_]\w*)\k<quote>/
  STAGE_NAME = /\A(?<base>\S+)(?:\s+AS\s+(?<name>\S+))?\z/i

  def self.parse(text)
    new(text).parse
  end

  def initialize(text)
    @lines = text.to_s.lines.map(&:chomp)
  end

  def parse
    directives = parse_directives
    escape = directives["escape"] == "`" ? "`" : "\\"

    instructions = parse_instructions(escape)
    stages = build_stages(instructions)

    Dash::Dockerfile::Document.new(instructions: instructions, stages: stages, directives: directives)
  end

  private
    attr_reader :lines

    # Only the comment block at the very top can carry directives; after the first
    # instruction a `# syntax=` line is an ordinary comment.
    def parse_directives
      directives = {}

      lines.each do |line|
        break unless line.match?(COMMENT) || line.match?(BLANK)
        next unless (match = line.match(DIRECTIVE))

        directives[match[:name].downcase] = match[:value]
      end

      directives
    end

    def parse_instructions(escape)
      instructions = []
      index = 0

      while index < lines.size
        line = lines[index]

        if line.match?(BLANK) || line.match?(COMMENT)
          index += 1
          next
        end

        started_at = index
        text, index = join_continuations(index, escape)
        text, index = append_heredocs(text, index)

        instruction = build_instruction(text, started_at + 1)
        instructions << instruction if instruction
      end

      instructions
    end

    # Joins physical lines while each ends in the escape character. Comment lines between
    # them are BuildKit's own convention for annotating a long RUN, and are not part of
    # the command.
    def join_continuations(index, escape)
      parts = []

      while index < lines.size
        line = lines[index]
        index += 1

        next if line.match?(COMMENT) && parts.any?

        continues = line.rstrip.end_with?(escape)
        parts << (continues ? line.rstrip.delete_suffix(escape) : line)
        break unless continues
      end

      [ parts.map(&:strip).reject(&:empty?).join(" "), index ]
    end

    # Every heredoc opened on the instruction line consumes lines until its delimiter, in
    # the order they were opened. The bodies are appended to the arguments so rules can
    # match what the instruction actually runs.
    #
    # A delimiter that never arrives means this was not a heredoc after all (`'<<EOF'` as
    # a quoted shell word, or a typo): nothing is consumed, so the rest of the file is
    # still parsed rather than folded into this one instruction.
    def append_heredocs(text, index)
      delimiters = text.scan(HEREDOC).map(&:last)
      return [ text, index ] if delimiters.empty?

      body = []
      at = index

      delimiters.each do |delimiter|
        terminator = (at...lines.size).find { |line| lines[line].strip == delimiter }
        return [ text, index ] unless terminator

        body.concat heredoc_commands(lines[at...terminator])
        at = terminator + 1
      end

      # Line breaks are kept: in a RUN heredoc each line is its own shell command, and the
      # apt rules need to know where one ends.
      [ [ text, *body ].join("\n"), at ]
    end

    # Inside the body the shell's own continuation applies: a line ending in `\` is the
    # same command as the next one.
    def heredoc_commands(body)
      body.map(&:strip).each_with_object([]) do |line, commands|
        if commands.last&.end_with?("\\")
          commands[-1] = "#{commands.last.delete_suffix("\\").rstrip} #{line}"
        else
          commands << line
        end
      end
    end

    def build_instruction(text, line)
      match = text.match(INSTRUCTION)
      return unless match

      flags, args = extract_flags(match[:rest].to_s.strip)

      Dash::Dockerfile::Instruction.new(name: match[:name].upcase, args: args, flags: flags, line: line)
    end

    def extract_flags(rest)
      flags = {}

      while (match = rest.match(FLAG))
        (flags[match[:key]] ||= []) << match[:value].delete_prefix('"').delete_suffix('"')
        rest = match.post_match.lstrip
      end

      [ flags, rest ]
    end

    def build_stages(instructions)
      stages = []

      instructions.each do |instruction|
        if instruction.name == "FROM"
          stages << new_stage(instruction, stages.size)
        elsif (stage = stages.last)
          stage.instructions << instruction
        end

        instruction.stage = stages.last unless stages.empty? && instruction.name != "FROM"
      end

      mark_shipped stages
      stages
    end

    def new_stage(instruction, index)
      match = instruction.args.match(STAGE_NAME)

      Dash::Dockerfile::Stage.new \
        name: match && match[:name] || "stage-#{index}",
        named: !(match && match[:name]).nil?,
        index: index,
        base: (match ? match[:base] : instruction.args),
        from: instruction
    end

    # Walk back from the final stage through the bases it inherits. A stage reached only
    # by `COPY --from=` is not on that chain, which is the point. Only an explicit `AS`
    # name can be inherited from; the generated `stage-N` labels are dash's, not BuildKit's.
    def mark_shipped(stages)
      by_name = stages.select(&:named?).to_h { |stage| [ stage.name, stage ] }
      stage = stages.last

      while stage && !stage.shipped?
        stage.shipped = true
        stage = by_name[stage.base]
      end
    end
end
