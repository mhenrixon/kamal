# Stage 3c migration: brings a host that still carries pre-rename container
# identity onto the renamed one.
#
# Three steps, run in this order on each proxy host before the normal boot:
#
#   1. Bridge the network. Docker cannot rename one, so `dash` is created
#      alongside `kamal` and everything still attached to the old network joins
#      the new one. App containers would be replaced by the next deploy anyway;
#      accessories are not, which is the whole reason this exists — without it a
#      renamed proxy cannot reach `db` or `redis`.
#
#   2. Copy the config volume. It holds the routing table and the ACME account
#      and certificate cache, so losing it means re-issuing every certificate
#      and spending Let's Encrypt rate limits to get back to where we were. This
#      must happen before the new container starts.
#
#   3. Replace the legacy container. A rename means the old container has to
#      release ports 80/443 before the new one can claim them, and no
#      port-holder handoff spans two container names — so this stage accepts a
#      brief outage per host. Deliberate; see zoolutions/dash#124.
#
# Every step is idempotent and guarded on its destination not already existing,
# so a second deploy is a no-op. Nothing here removes the legacy network or
# volume: an operator who wants them gone removes them by hand, and stage 3d
# deletes this class outright.
#
# All three travel as one command (Dash::Commands::Proxy#prepare_boot), guarded on a
# marker the host writes once it is verifiably past the rename - so a migrated host, and
# a host installed fresh on 4.x that never had a kamal-proxy, run no docker command here
# at all. The round trip itself is one the host already pays: the command carries the
# apps-config `mkdir -p` too, which reads nothing the bridge writes. Stage 3d keeps the
# mkdir and deletes the rest.
class Dash::Cli::Proxy::LegacyRename
  attr_reader :host, :sshkit
  delegate :execute, to: :sshkit

  def initialize(host, sshkit)
    @host = host
    @sshkit = sshkit
  end

  def run
    execute *DASH.proxy(host).prepare_boot
  end
end
