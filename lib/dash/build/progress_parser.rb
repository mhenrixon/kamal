# Reads `docker buildx build --progress=plain` as it streams past and turns it into a
# per-step report. It is an SSHKit interaction handler, so it sees the same bytes SSHKit
# is already printing — no second process, no `docker buildx history`, no extra command.
#
# The stream is line-oriented but arrives in chunks (the SSH backend splits on packet
# boundaries, not newlines), so data is buffered and only whole lines are parsed. Every
# line belongs to a vertex — `#12` — and the first line for a vertex names it; the rest
# are events on it (DONE, CACHED, ERROR) or its own stdout, which is ignored.
#
# Nothing here may raise into a build. A parse error stops the parsing and is reported
# once by the caller; the deploy keeps whatever was collected up to that point.
class Dash::Build::ProgressParser
  VERTEX = /\A#(?<number>\d+)(?: (?<rest>.*))?\z/

  # `[linux/amd64 build 2/3] RUN …` — the platform prefix only appears on multi-platform
  # builds, and the stage name only when the Dockerfile named it with AS.
  STEP = %r{\A\[(?:(?<platform>[a-z0-9]+/[a-z0-9][\w./-]*) )?(?:(?<stage>[A-Za-z0-9][\w.-]*) )?(?<ordinal>\d+)/(?<steps_in_stage>\d+)\] (?<instruction>.+)\z}
  INTERNAL = /\A\[(?:\S+ )?internal\] (?<what>.+)\z/
  DONE = /\ADONE (?<seconds>\d+(?:\.\d+)?)s\z/
  ERROR = /\AERROR: (?<message>.+)\z/
  TRANSFERRING_CONTEXT = /\Atransferring context: (?<size>[\d.]+)(?<unit>[a-zA-Z]+)(?: (?<seconds>\d+(?:\.\d+)?)s)? done\z/
  PUSHING = /\Apushing .*?(?<seconds>\d+(?:\.\d+)?)s done\z/

  BYTE_UNITS = { "b" => 1, "kb" => 1_000, "mb" => 1_000_000, "gb" => 1_000_000_000, "tb" => 1_000_000_000_000 }.freeze

  attr_reader :error

  def initialize
    @steps = {}
    @order = []
    @buffer = +""
    @push_seconds = 0.0
    @mutex = Mutex.new
  end

  # SSHKit's interaction-handler contract.
  def on_data(_command, _stream_name, data, _channel)
    @mutex.synchronize do
      next if @error

      @buffer << data.to_s
      while (newline = @buffer.index("\n"))
        parse_line @buffer.slice!(0..newline).chomp
      end
    rescue StandardError => e
      @error = e
    end
  end

  # The last line of a build has no trailing newline when the command dies mid-write.
  def finish
    @mutex.synchronize do
      next if @error

      parse_line @buffer.chomp unless @buffer.empty?
      @buffer = +""
    rescue StandardError => e
      @error = e
    end
  end

  def result
    @mutex.synchronize do
      Dash::Build::Report.new(steps: @order.map { |number| @steps[number] }, push_seconds: @push_seconds)
    end
  end

  private
    def parse_line(line)
      match = VERTEX.match(line) or return
      rest = match[:rest].to_s.strip

      # `#3 ...` is buildx saying the vertex is deferred, not a step of its own.
      return if rest.empty? || rest == "..."

      number = match[:number].to_i
      step = @steps[number]

      unless step
        step = @steps[number] = build_step(number, rest)
        @order << number
      end

      update step, rest
    end

    def build_step(number, rest)
      Dash::Build::Step.new(number, kind: :other, name: rest).tap do |step|
        if (match = STEP.match(rest))
          step.platform = match[:platform]
          step.stage = match[:stage]
          step.ordinal = match[:ordinal].to_i
          step.steps_in_stage = match[:steps_in_stage].to_i
          step.instruction = match[:instruction].squeeze(" ").strip
          step.kind = step.instruction.start_with?("FROM ") ? :from : :instruction
        elsif (match = INTERNAL.match(rest))
          step.kind = internal_kind(match[:what])
        elsif rest.start_with?("exporting cache")
          step.kind = :cache_export
        elsif rest.match?(/\A(exporting|pushing|writing image)/)
          step.kind = :export
        end
      end
    end

    def internal_kind(what)
      case what
      when /\Aload build context/ then :context
      when /\Aload metadata for/ then :metadata
      else :other
      end
    end

    # Later lines for a vertex are its result, its output, or its progress. buildx
    # re-reports DONE per platform on a multi-platform build, so the last one wins.
    def update(step, rest)
      if (match = DONE.match(rest))
        step.seconds = match[:seconds].to_f
      elsif rest == "CACHED"
        step.cached = true
        step.seconds = 0.0
      elsif (match = ERROR.match(rest))
        step.error = match[:message]
      elsif (match = TRANSFERRING_CONTEXT.match(rest)) && step.kind == :context
        step.bytes = bytes(match[:size], match[:unit])
        step.seconds ||= match[:seconds]&.to_f
      elsif (match = PUSHING.match(rest)) && step.kind == :export
        @push_seconds += match[:seconds].to_f
      end
    end

    # buildx reports decimal units — 25.18MB is 25,180,000 bytes, not 25.18 MiB.
    def bytes(size, unit)
      (size.to_f * BYTE_UNITS.fetch(unit.downcase, 1)).round
    end
end
