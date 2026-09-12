class Dash::Commands::Loadbalancer < Dash::Commands::Base
  include Dash::Commands::Proxy::CertTransfer

  delegate :argumentize, :optionize, to: Dash::Utils

  attr_reader :loadbalancer_config

  def initialize(config, loadbalancer_config: nil)
    super(config)
    @loadbalancer_config = loadbalancer_config
  end

  def run
    docker \
      :run,
      "--name", container_name,
      "--network", "dash",
      "--detach",
      "--restart", "unless-stopped",
      "--label", label,
      "--label", "#{Dash::Commands::Proxy::CONFIG_DIGEST_LABEL}=#{loadbalancer_config.run_config_digest}",
      *config_volume,
      *run_args,
      *loadbalancer_config.run.image,
      *loadbalancer_config.run.run_command
  end

  def start
    docker :container, :start, container_name
  end

  def stop(name: container_name)
    docker :container, :stop, name
  end

  def start_or_run
    combine start, run, by: "||"
  end

  # A dedicated load balancer host went through the 4.0 rename with nothing
  # adopting its `kamal-loadbalancer-config` volume: the per-host proxies got
  # Dash::Cli::Proxy::LegacyRename, the load balancer got a fresh empty volume
  # and lost its routing table, dynamic domains and ACME cache. On a shared
  # proxy host the volume is the proxy's own and LegacyRename already copied
  # it, so this is a no-op there.
  def copy_legacy_config_volume
    copy_legacy_volume(legacy: legacy_config_volume_name, volume: config_volume_name, image: loadbalancer_config.run.image)
  end

  # Everything this host needs before anything reads its container, volume or network,
  # in the one round trip it already pays for the apps-config directory. Same shape as
  # Dash::Commands::Proxy#prepare_boot, including why the guard has to be the first word.
  def prepare_boot
    combine legacy_rename, ensure_apps_config_directory
  end

  # The loadbalancer's half of the stage-3c bridge - network, then volume - skipped
  # outright by a host that has already been through it. No legacy container is replaced
  # here (a dedicated loadbalancer host never ran one under a name this gem knows), so
  # the marker is verified on the volume instead: the new one exists, or there was never
  # a legacy one to adopt. Stage 3d deletes this with the rest of the bridge.
  def legacy_rename
    any \
      [ :test, "-f", legacy_rename_marker ],
      group(
        group(docker_commands.connect_legacy_network_containers),
        group(copy_legacy_config_volume),
        group(any(mark_legacy_renamed, [ :true ]))
      )
  end

  def deploy(targets: [])
    docker :exec, container_name, "dash-proxy", "deploy", loadbalancer_config.config.service,
      *loadbalancer_config.deploy_command_args(targets: targets)
  end

  # `retry` takes a host, or --all; the rest take no arguments.
  def domains(subcommand, *args)
    docker :exec, container_name, "dash-proxy", "domains", subcommand, *args
  end

  def list(json: false)
    docker :exec, container_name, "dash-proxy", :list, *("--json" if json)
  end

  # Cache policy is edge-only under load balancing (see the layering contract),
  # so the cache admin surface lives here - registered under the bare service
  # name, unlike the per-role services on the proxy hosts.
  def cache_stats(count: false, json: false)
    docker :exec, container_name, "dash-proxy", :cache, :stats, *optionize({ count: count || nil, json: json || nil }.compact)
  end

  def cache_purge(service, path_prefix: nil)
    docker :exec, container_name, "dash-proxy", :cache, :purge, service, *optionize({ "path-prefix": path_prefix }.compact)
  end

  def config_digest
    docker :inspect, container_name, "--format", Dash::Commands::Proxy::CONFIG_DIGEST_FORMAT
  end

  # One read for container id, image tag and config digest - parsed by
  # Dash::Commands::Proxy::State, same as the per-host proxy's.
  def inspect_state
    docker :inspect, container_name, "--format", Dash::Commands::Proxy::STATE_FORMAT
  end

  def container_id(only_running: false)
    container_id_for(container_name: container_name, only_running: only_running)
  end

  def info
    docker :ps, "--filter", "'name=^#{container_name}$'"
  end

  def version
    pipe \
      docker(:inspect, container_name, "--format '{{.Config.Image}}'"),
      [ :cut, "-d:", "-f2" ]
  end

  def logs(timestamps: true, since: nil, lines: nil, grep: nil, grep_options: nil)
    pipe \
      docker(:logs, container_name, ("--since #{since}" if since), ("--tail #{lines}" if lines), ("--timestamps" if timestamps), "2>&1"),
      ("grep '#{grep}'#{" #{grep_options}" if grep_options}" if grep)
  end

  def follow_logs(host:, timestamps: true, grep: nil, grep_options: nil)
    run_over_ssh pipe(
      docker(:logs, container_name, ("--timestamps" if timestamps), "--tail", "10", "--follow", "2>&1"),
      (%(grep "#{grep}"#{" #{grep_options}" if grep_options}) if grep)
    ).join(" "), host: host
  end

  # Prune by the label the container was actually created with - on a shared
  # proxy host that is the dash-proxy title, and pruning by the loadbalancer
  # title would leave the container behind for `run` to collide with. Both the
  # current and the pre-rename title are pruned, so a container created before
  # the rename is not left behind to collide either.
  def remove_container
    combine \
      prune_containers_titled(image_title),
      prune_containers_titled(legacy_image_title)
  end

  # Image label filters match labels baked into the image, and the load balancer
  # runs the dash-proxy image whichever host it sits on. Both titles are matched
  # so a host still carrying a pre-rename image is cleaned up too; Docker ANDs
  # multiple `--filter label=` values, so that is two commands.
  def remove_image
    combine \
      prune_images_titled(Dash::Configuration::Proxy::IMAGE_TITLE),
      prune_images_titled(Dash::Configuration::Proxy::LEGACY_IMAGE_TITLE)
  end

  def ensure_directory
    make_directory loadbalancer_config.directory
  end

  # Where the proxy secrets env file lands (see Proxy::Run#secrets_path) -
  # the same .dash/proxy directory the per-app proxy hosts use.
  def ensure_proxy_directory
    make_directory loadbalancer_config.run.host_directory
  end

  def remove_proxy_secrets_file
    remove_file loadbalancer_config.run.secrets_path
  end

  def ensure_apps_config_directory
    make_directory config.proxy_boot.apps_directory
  end

  def ensure_services_directory
    make_directory loadbalancer_config.services_directory
  end

  def read_service_owner
    read_file loadbalancer_config.service_owner_file
  end

  def read_run_config_record
    read_file loadbalancer_config.run_config_file
  end

  def remove_directory
    super(loadbalancer_config.directory)
  end

  def container_name
    loadbalancer_config.container_name
  end

  private
    # Stage 3c. 3d deletes both of these with the rest of the bridge.
    def legacy_rename_marker
      File.join loadbalancer_config.directory, Dash::Configuration::Proxy::LEGACY_RENAME_MARKER
    end

    # Verified on the volume existing, not on a container being gone - the loadbalancer
    # replaces no legacy container, so this is the only signal its bridge has. That makes
    # it foolable in one specific way: if `dash-loadbalancer-config` comes to exist before
    # this bridge ever runs on a host, the marker is written despite the legacy volume's
    # routing table and ACME cache never having been copied. The fix is upstream of the
    # heuristic rather than in it - every path that can create the container, and with it
    # the volume `docker run --volume` auto-creates empty, runs the bridge first:
    # `boot`, both reboots (Dash::Cli::Proxy::Reboot, Dash::Cli::Proxy::LoadbalancerReboot)
    # and `dash proxy loadbalancer start` (zoolutions/dash#168).
    #
    # If a host is somehow in that state anyway - an operator's own `docker run`, a
    # volume created by hand - recovery is to copy the legacy volume's contents over,
    # then remove .legacy-renamed under this host's loadbalancer directory so this
    # re-evaluates.
    def mark_legacy_renamed
      combine \
        group(any(volume_exists(config_volume_name), negate(volume_exists(legacy_config_volume_name)))),
        make_directory(loadbalancer_config.directory),
        [ :touch, legacy_rename_marker ]
    end

    def run_args
      loadbalancer_config.run_args
    end

    def on_proxy_host?
      loadbalancer_config.on_proxy_host?
    end

    # The full `key=value` the container is created with, so `--label #{label}`
    # stays correct. The prune helpers take a bare title instead.
    def label
      "org.opencontainers.image.title=#{image_title}"
    end

    def image_title
      if on_proxy_host?
        Dash::Configuration::Proxy::IMAGE_TITLE
      else
        Dash::Configuration::Proxy::LOADBALANCER_IMAGE_TITLE
      end
    end

    def legacy_image_title
      if on_proxy_host?
        Dash::Configuration::Proxy::LEGACY_IMAGE_TITLE
      else
        Dash::Configuration::Proxy::LEGACY_LOADBALANCER_IMAGE_TITLE
      end
    end

    def prune_containers_titled(title)
      docker :container, :prune, "--force", "--filter", "label=org.opencontainers.image.title=#{title}"
    end

    def prune_images_titled(title)
      docker :image, :prune, "--all", "--force", "--filter", "label=org.opencontainers.image.title=#{title}"
    end

    # dash-proxy keeps its state under /home/dash-proxy/.config/dash-proxy
    # whichever host it runs on - only the volume name differs, so a dedicated
    # load balancer and a shared proxy host never fight over the same volume.
    # (The apps-config mount comes with run_args, via the proxy's run surface.)
    def config_volume
      [ "--volume", "#{config_volume_name}:/home/dash-proxy/.config/dash-proxy" ]
    end

    def config_volume_name
      on_proxy_host? ? Dash::Configuration::Proxy::CONFIG_VOLUME : Dash::Configuration::Proxy::LOADBALANCER_CONFIG_VOLUME
    end

    def legacy_config_volume_name
      on_proxy_host? ? Dash::Configuration::Proxy::LEGACY_CONFIG_VOLUME : Dash::Configuration::Proxy::LEGACY_LOADBALANCER_CONFIG_VOLUME
    end

    # The certificate store lives in whichever config volume this loadbalancer
    # actually mounts — the shared dash-proxy one on a proxy host.
    def cert_store_volume_args
      config_volume
    end

    def one_off_image
      [ loadbalancer_config.run.image ]
    end
end
