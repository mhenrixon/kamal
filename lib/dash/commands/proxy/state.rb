# What one `docker inspect` of a proxy container tells a boot: whether it exists, which
# image tag it runs, and the config digest it was booted with. Three questions that used
# to cost three round trips each (`container_id`, `version`, `config_digest`).
#
# Produced by Dash::Commands::Proxy#inspect_state and its loadbalancer twin, both of which
# are captured with raise_on_non_zero_exit: false - a host with no container inspects to
# empty output, which parses to a state that simply does not exist.
class Dash::Commands::Proxy::State
  attr_reader :id, :image, :digest

  def self.parse(output)
    id, image, digest = output.to_s.strip.split(" ", 3)
    new(id: id, image: image, digest: digest)
  end

  def initialize(id: nil, image: nil, digest: nil)
    @id = id.presence
    @image = image.presence
    @digest = digest.presence
  end

  def exists?
    id.present?
  end

  # The tag, read the way Dash::Commands::Proxy#version reads it - everything past the
  # LAST colon, so a registry host carrying a port does not get mistaken for the version.
  def version
    image&.split(":")&.last
  end
end
