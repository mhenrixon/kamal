# One build stage: everything from a FROM up to the next one.
#
# `shipped?` is the distinction that matters for advice. A stage only reachable through
# `COPY --from=` contributes files, not layers, so apt hygiene and a missing USER in it
# say nothing about the image that ends up on the server. The last stage is shipped, and
# so is anything it (transitively) builds FROM.
class Dash::Dockerfile::Stage
  IMAGE_REF = /\A(?<image>[^:@\s]+)(?::(?<tag>[^@\s]+))?(?:@(?<digest>\S+))?\z/
  INTERPOLATION = /\$\{?\w+\}?/

  attr_reader :name, :index, :base, :instructions
  attr_writer :shipped

  def initialize(name:, index:, base:, from:)
    @name = name
    @index = index
    @base = base
    @from = from
    @instructions = [ from ]
    @shipped = false
  end

  def shipped?
    @shipped
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
  # base the latest-base rule is looking for.
  def interpolated_tag?
    base.match?(INTERPOLATION)
  end

  private
    def ref
      @ref ||= base.match(IMAGE_REF) || {}
    end
end
