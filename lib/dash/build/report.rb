# What the build actually spent its time on, derived from the buildx progress stream.
#
# "Steps" here means the operator's own Dockerfile steps — the vertices buildx numbered
# `[stage k/m]`. BuildKit's own bookkeeping (booting, auth tokens, metadata lookups) is
# kept in `steps` because it is still time the build took, but it is never counted as a
# step the operator wrote.
class Dash::Build::Report
  attr_reader :steps, :push_seconds

  def initialize(steps: [], push_seconds: 0.0)
    @steps = steps
    @push_seconds = push_seconds
  end

  def any?
    steps.any?
  end

  def dockerfile_steps
    steps.select(&:dockerfile_step?)
  end

  def instruction_steps
    steps.select { |step| step.kind == :instruction }
  end

  def cached_steps
    dockerfile_steps.select(&:cached)
  end

  def uncached_steps
    dockerfile_steps.reject(&:cached)
  end

  # The rows worth printing: the operator's own instructions, longest first. A FROM or a
  # metadata lookup is not something they can speed up by editing the Dockerfile.
  def slowest(count)
    instruction_steps.reject(&:cached).sort_by { |step| -step.seconds.to_f }.first(count)
  end

  def context_step
    steps.find { |step| step.kind == :context }
  end

  def context_bytes
    context_step&.bytes
  end

  def context_seconds
    context_step&.seconds
  end

  def export_seconds
    seconds_for(:export)
  end

  def cache_export_seconds
    seconds_for(:cache_export)
  end

  def total_step_seconds
    steps.sum { |step| step.seconds.to_f }
  end

  def errors
    steps.select(&:error)
  end

  # The errors worth putting in front of an operator. BuildKit reports a cache-import
  # miss as an ERROR on its own vertex — the first build against a fresh cache always
  # has one — and a row saying "error" for something that did not fail the build teaches
  # people to ignore the column.
  def failed_steps
    errors.select { |step| step.dockerfile_step? || step.kind == :export }
  end

  def to_h
    {
      context_bytes: context_bytes,
      context_seconds: context_seconds,
      cached_steps: cached_steps.size,
      total_steps: dockerfile_steps.size,
      export_seconds: export_seconds,
      cache_export_seconds: cache_export_seconds,
      push_seconds: push_seconds,
      total_step_seconds: total_step_seconds,
      steps: steps.map(&:to_h)
    }
  end

  private
    def seconds_for(kind)
      steps.sum { |step| step.kind == kind ? step.seconds.to_f : 0.0 }
    end
end
