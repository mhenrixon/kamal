require "json"

# One logical Dockerfile instruction: the keyword, its flags, and everything else on the
# line — continuations joined, heredoc bodies appended, comments dropped.
#
# `line` is the first physical line the instruction started on, because that is the line
# an operator opens their editor at when advice names it.
class Dash::Dockerfile::Instruction
  attr_reader :name, :args, :flags, :line
  attr_accessor :stage

  def initialize(name:, args:, flags: {}, line: 1)
    @name = name
    @args = args
    @flags = flags
    @line = line
  end

  # The first value of a flag. Repeated flags (several `--mount`s on one RUN) keep every
  # value in `flags`; callers that only care whether one is present ask for the first.
  def flag(key)
    Array(flags[key]).first
  end

  def flag?(key)
    flags.key?(key)
  end

  def json?
    args.start_with?("[") && !argv.nil?
  end

  # The exec form's arguments, or nil when this is the shell form (or malformed JSON,
  # which BuildKit would reject but which must not take the analyzer down with it).
  def argv
    return @argv if defined?(@argv)

    @argv = begin
      parsed = JSON.parse(args) if args.start_with?("[")
      parsed if parsed.is_a?(Array) && parsed.all?(String)
    rescue JSON::ParserError
      nil
    end
  end

  # What the instruction runs, as one string, whichever form it was written in — the
  # rules match against shell text and should not have to care.
  def shell_command
    json? ? argv.join(" ") : args
  end

  # Collapsed to a single line so it can be compared with what buildx printed for the
  # matching vertex, and so advice can name it without wrapping the terminal.
  def to_s
    [ name, *flags.flat_map { |key, values| values.map { |value| "--#{key}=#{value}" } }, args ]
      .reject(&:blank?).join(" ").gsub(/\s+/, " ")
  end
end
