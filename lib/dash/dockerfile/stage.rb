# One build stage: everything from a FROM up to the next one.
#
# `shipped?` is the distinction that matters for advice. A stage only reachable through
# `COPY --from=` contributes files, not layers, so apt hygiene and a missing USER in it
# say nothing about the image that ends up on the server. The last stage is shipped, and
# so is anything it (transitively) builds FROM.
class Dash::Dockerfile::Stage
  # A registry may carry a port (`localhost:5000/app`), so the tag is only what follows a
  # colon in the last path segment.
  IMAGE_REF = %r{\A(?<image>(?:[^/@\s]+/)*[^:/@\s]+)(?::(?<tag>[^@\s]+))?(?:@(?<digest>\S+))?\z}
  INTERPOLATION = /\$\{?\w+\}?/
  # Docker's reserved empty base: nothing to pin, nothing to resolve.
  SCRATCH = "scratch".freeze

  attr_reader :name, :index, :base, :instructions
  attr_writer :shipped

  def initialize(name:, index:, base:, from:, named: true)
    @name = name
    @named = named
    @index = index
    @base = base
    @from = from
    @instructions = [ from ]
    @shipped = false
  end

  def shipped?
    @shipped
  end

  # An explicit `AS` name, as opposed to the `stage-N` label dash generates.
  def named?
    @named
  end

  def scratch?
    base == SCRATCH
  end

  def image
    ref[:image]
  end

  def tag
    ref[:tag]
  end

  def digest
    ref[:digest]
  end

  # `FROM ruby:$RUBY_VERSION` pins a version through an ARG, so it is not the unpinned
  # base the latest-base rule is looking for. With no tag at all, `FROM $IMAGE` might be
  # carrying one inside the variable — unknowable, so it passes too. An explicit `:latest`
  # is explicit whatever the registry in front of it was.
  def interpolated_tag?
    (tag || image).to_s.match?(INTERPOLATION)
  end

  private
    def ref
      @ref ||= base.match(IMAGE_REF) || {}
    end
end
