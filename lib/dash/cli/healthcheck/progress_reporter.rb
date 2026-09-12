# Turns the server-side readiness wait's progress lines back into the beacon the
# client-side poll used to print. It is an SSHKit interaction handler, so it sees the
# wait's stderr as it streams — the operator gets the same once-a-second feedback they
# got when the laptop was the thing doing the polling, for one round trip instead of one
# per attempt. The cadence is fixed at a second because the host loop's is.
#
# The stream is line-oriented but arrives in chunks (the SSH backend splits on packet
# boundaries, not newlines), so data is buffered and only whole lines are reported. Only
# stderr is buffered: the wait's stdout carries the final status, and stdout and stderr are
# separate SSH streams whose chunks can interleave — folding both into one buffer would let
# the status land in the middle of a half-arrived progress line and corrupt them both.
# Anything on stderr that is not a progress line (docker's own complaints) is ignored.
class Dash::Cli::Healthcheck::ProgressReporter
  LINE = /\A#{Regexp.escape(Dash::Commands::Base::READINESS_PROGRESS_PREFIX)} (?<elapsed>\d+) (?<left>\d+)(?: |\z)/

  def initialize
    @buffer = +""
    @mutex = Mutex.new
  end

  # SSHKit's interaction-handler contract.
  def on_data(_command, stream_name, data, _channel = nil)
    return unless stream_name == :stderr

    @mutex.synchronize do
      @buffer << data.to_s
      while (newline = @buffer.index("\n"))
        report @buffer.slice!(0..newline).chomp
      end
    end
  end

  private
    def report(line)
      match = LINE.match(line) or return

      SSHKit.config.output.info "Container not ready yet, retrying in 1s (#{match[:elapsed]}s elapsed, #{match[:left]}s left)"
    end
end
