class Dash::Cli::Prune < Dash::Cli::Base
  desc "all", "Prune unused images and stopped containers"
  def all
    modify(lock: true, server_lock: true) do
      containers
      images
    end
  end

  desc "images", "Prune unused images"
  def images
    modify(lock: true, server_lock: true) do
      on(DASH.hosts) do
        execute *DASH.auditor.record_then("Pruned images", DASH.prune.dangling_images, DASH.prune.tagged_images)
      end
    end
  end

  desc "containers", "Prune all stopped containers, except the last n per role (default 5)"
  option :retain, type: :numeric, default: nil, desc: "Number of containers to retain per role"
  def containers
    retain = options.fetch(:retain, DASH.config.retain_containers)
    raise "retain must be at least 1" if retain < 1

    modify(lock: true, server_lock: true) do
      on(DASH.hosts) do |host|
        # One round trip per host, whatever it runs: a host with no app roles still
        # records that the sweep reached it.
        execute *DASH.auditor.record_then("Pruned containers",
          *DASH.roles_on(host).map { |role| DASH.prune.app_containers(retain: retain, role: role) })
      end
    end
  end
end
