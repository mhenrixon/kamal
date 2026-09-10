# One buildx vertex. A vertex is a unit of work BuildKit reports on: a Dockerfile
# instruction, the context transfer, a metadata lookup, the export to the registry.
#
# Only the ones with an ordinal (`[build 5/9]`) are the operator's own steps — the rest
# are BuildKit's own bookkeeping, and counting them would make "cached steps 9 of 22"
# say something nobody asked.
class Dash::Build::Step
  attr_reader :number
  attr_accessor :kind, :name, :platform, :stage, :ordinal, :steps_in_stage, :instruction, :seconds, :cached, :error, :bytes

  def initialize(number, kind: :other, name: nil)
    @number = number
    @kind = kind
    @name = name
    @cached = false
  end

  # What buildx itself printed for this vertex, minus the platform prefix it adds on a
  # multi-platform build — the operator matches these against their Dockerfile, and the
  # platform is already its own column in the data.
  def label
    ordinal ? "[#{[ stage, "#{ordinal}/#{steps_in_stage}" ].compact.join(" ")}] #{instruction}" : name.to_s
  end

  def dockerfile_step?
    !ordinal.nil?
  end

  def to_h
    { number: number, kind: kind, label: label, platform: platform, stage: stage, ordinal: ordinal,
      instruction: instruction, seconds: seconds, cached: cached, bytes: bytes, error: error }
  end
end
