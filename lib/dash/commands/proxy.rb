class Dash::Commands::Proxy < Dash::Commands::Base
  include Dash::Commands::Proxy::CertTransfer

  delegate :argumentize, :optionize, to: Dash::Utils
  attr_reader :proxy_run_config

  CONFIG_DIGEST_LABEL = "org.dash.proxy-config-digest"

  # Containers booted before the stage-3b rename carry the old key. New ones are
  # labelled with CONFIG_DIGEST_LABEL only, but reads fall back to the legacy key
  # so upgrading doesn't read as config drift and reboot every proxy for nothing.
  # Both the legacy constant and the fallback go away in stage 3d.
  LEGACY_CONFIG_DIGEST_LABEL = "org.kamal.proxy-config-digest"

  CONFIG_DIGEST_TEMPLATE = "{{ with index .Config.Labels \"#{CONFIG_DIGEST_LABEL}\" }}{{ . }}" \
    "{{ else }}{{ index .Config.Labels \"#{LEGACY_CONFIG_DIGEST_LABEL}\" }}{{ end }}"

  CONFIG_DIGEST_FORMAT = "'#{CONFIG_DIGEST_TEMPLATE}'"

  # Everything Dash::Cli::Proxy::Drift and the minimum-version gate need, in one format.
  STATE_FORMAT = "'{{.Id}} {{.Config.Image}} #{CONFIG_DIGEST_TEMPLATE}'"

  def initialize(config, host:)
    super(config)
    @proxy_run_config = config.proxy_run(host)
  end

  def run(digest: nil, name: nil)
    if proxy_run_config
      docker \
        :run,
        "--name", name || container_name,
        *proxy_run_config.network_args,
        "--detach",
        "--restart", "unless-stopped",
        "--volume", "dash-proxy-config:/home/dash-proxy/.config/dash-proxy",
        *config_digest_label_args(digest),
        *proxy_run_config.docker_options_args,
        *proxy_run_config.image,
        *proxy_run_config.run_command
    else
      pipe boot_config, xargs(docker_run(digest: digest))
    end
  end

  # Stage 3c migrations. All three are idempotent and guarded on the
  # destination not existing, so a second deploy is a no-op. Stage 3d deletes
  # them along with the legacy constants they read.

  # Everything a proxy host needs before anything reads its container, volume or
  # network, in the one round trip it already pays for the apps-config directory.
  #
  # `a || b && c` is `(a || b) && c`, so the mkdir runs whichever way the guard went -
  # and the guard has to be the first word rather than a parenthesised group, because
  # SSHKit prefixes the first word with /usr/bin/env and passes only `test` through.
  # Stage 3d drops the legacy_rename half and leaves the mkdir.
  def prepare_boot
    combine legacy_rename, ensure_apps_config_directory
  end

  # The whole stage-3c bridge as one command, skipped outright by a host that has
  # already been through it - or was installed fresh on 4.x and never had a kamal-proxy.
  # The three steps keep their own bodies and their documented order (see
  # Dash::Cli::Proxy::LegacyRename); each is wrapped in its own subshell because they
  # all mix && and || at one precedence level, and composing them flat would
  # re-associate across the volume copy's guard - the chain 4.0.0 got wrong.
  #
  # The marker is written on verified absence of both legacy containers, never on the
  # chain's exit status: the two removals end in `|| true`, so a host whose stop failed
  # would otherwise record itself as migrated and never retry. Its own `|| true` keeps
  # that failure as quiet as it is today, while a failed volume copy still exits
  # non-zero through the && chain and aborts the boot exactly as it does now.
  def legacy_rename
    any \
      [ :test, "-f", legacy_rename_marker ],
      group(
        group(docker_commands.connect_legacy_network_containers),
        group(copy_legacy_config_volume),
        group(remove_legacy_container(timeout: config.drain_timeout)),
        group(remove_legacy_holder_container),
        group(any(mark_legacy_renamed, [ :true ]))
      )
  end

  # Copies the pre-rename config volume into the new one, before anything
  # starts. The volume holds the routing table and the ACME account and
  # certificate cache; losing it means re-issuing every certificate and
  # spending Let's Encrypt rate limits to get back where we were.
  #
  # Runs in the dash-proxy image itself — already pulled by this point in the
  # boot sequence, and its ubuntu base has sh and cp. `--user root` because the
  # image's own user cannot write the destination volume; `cp -a` preserves the
  # uid, which the rename leaves at 1001.
  #
  # Shape: `exists || ! legacy_exists || ( create && copy )`. The chain has to
  # start with a real program: SSHKit prefixes the first word with
  # `/usr/bin/env`, and `env !` is "No such file or directory" (exit 127), not
  # shell negation. 4.0.0 led with `! docker volume inspect …`, so the whole
  # chain failed silently into `|| true`, the proxy booted onto a volume docker
  # created empty, and every host lost its routing table and ACME cache on the
  # first deploy. The subshell groups create-and-copy because `&&` and `||`
  # share precedence and associate left — without it a host that already has
  # the new volume would still run the copy over live state.
  def copy_legacy_config_volume(volume: Dash::Configuration::Proxy::CONFIG_VOLUME, legacy: Dash::Configuration::Proxy::LEGACY_CONFIG_VOLUME)
    copy_legacy_volume(legacy: legacy, volume: volume, image: proxy_image)
  end

  # Stops and removes a pre-rename proxy container so the renamed one can claim
  # ports 80/443. No port-holder handoff spans two container names, which is
  # why this stage accepts a brief outage per host.
  def remove_legacy_container(timeout: nil)
    any \
      combine(
        container_exists(Dash::Configuration::Proxy::LEGACY_CONTAINER_NAME),
        docker(:container, :stop, *("--time=#{timeout}" if timeout), Dash::Configuration::Proxy::LEGACY_CONTAINER_NAME),
        docker(:container, :rm, Dash::Configuration::Proxy::LEGACY_CONTAINER_NAME)
      ),
      [ :true ]
  end

  def remove_legacy_holder_container
    any \
      combine(
        container_exists(Dash::Configuration::Proxy::LEGACY_HOLDER_CONTAINER_NAME),
        docker(:container, :rm, "--force", Dash::Configuration::Proxy::LEGACY_HOLDER_CONTAINER_NAME)
      ),
      [ :true ]
  end

  def start
    docker :container, :start, container_name
  end

  def stop(name: container_name, timeout: nil)
    docker :container, :stop, *("--time #{timeout}" if timeout), name
  end

  def start_or_run(digest: nil)
    combine start, run(digest: digest), by: "||"
  end

  def info
    docker :ps, "--filter", "'name=^#{container_name}$'"
  end

  # `name:` so the doctor can also ask about the pre-rename container: during
  # the stage-3c transition a host still runs kamal-proxy, and a check that only
  # ever looks at dash-proxy concludes no proxy is running.
  def version(name: container_name)
    pipe \
      docker(:inspect, name, "--format '{{.Config.Image}}'"),
      [ :awk, "-F:", "'{print \$NF}'" ]
  end

  def config_digest
    docker :inspect, container_name, "--format", CONFIG_DIGEST_FORMAT
  end

  # One read for container id, image tag and config digest - parsed by
  # Dash::Commands::Proxy::State. Capture it with raise_on_non_zero_exit: false;
  # a host with no proxy container inspects to nothing, which is an answer.
  def inspect_state
    docker :inspect, container_name, "--format", STATE_FORMAT
  end

  def container_id(only_running: false)
    container_id_for(container_name: container_name, only_running: only_running)
  end

  def pull
    if proxy_run_config
      docker :pull, proxy_run_config.image
    else
      docker :pull, "#{substitute(read_image)}:#{substitute(read_image_version)}"
    end
  end

  def list(name: container_name, json: false)
    docker :exec, name, "dash-proxy", :list, *("--json" if json)
  end

  def cache_stats(count: false, json: false)
    docker :exec, container_name, "dash-proxy", :cache, :stats, *optionize({ count: count || nil, json: json || nil }.compact)
  end

  def cache_purge(service, path_prefix: nil)
    docker :exec, container_name, "dash-proxy", :cache, :purge, service, *optionize({ "path-prefix": path_prefix }.compact)
  end

  # One mount destination per line - what the running container was actually
  # booted with, as opposed to what the current configuration would mount.
  def mount_destinations
    docker :inspect, container_name, "--format", "'{{range .Mounts}}{{println .Destination}}{{end}}'"
  end

  # Zero-downtime handoff commands (proxy/run port_holder mode)

  def port_holder?
    proxy_run_config&.port_holder? || false
  end

  def next_container_name
    "#{container_name}-next"
  end

  def run_holder
    docker \
      :run,
      "--name", proxy_run_config.holder_container_name,
      "--network", "dash",
      "--detach",
      "--restart", "unless-stopped",
      *proxy_run_config.holder_docker_args,
      *proxy_run_config.image,
      "dash-proxy", "hold"
  end

  def start_holder_or_run
    combine docker(:container, :start, proxy_run_config.holder_container_name), run_holder, by: "||"
  end

  def holder_container_id
    container_id_for(container_name: proxy_run_config.holder_container_name, only_running: true)
  end

  # Cancel the restart policy before draining: drain makes the proxy exit on
  # its own, which - unlike `docker stop` - an active restart policy would undo.
  def disable_restart
    docker :update, "--restart=no", container_name
  end

  def drain(timeout: nil)
    docker :exec, container_name, "dash-proxy", :drain, *("--drain-timeout=#{timeout}s" if timeout)
  end

  def wait_for_exit(name: container_name)
    docker :wait, name
  end

  def remove_stopped_container(name: container_name)
    docker :container, :rm, name
  end

  def promote_next_container
    docker :container, :rename, next_container_name, container_name
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

  # `retry` takes a host, or --all; the rest take no arguments.
  def domains(subcommand, *args)
    docker :exec, container_name, "dash-proxy", "domains", subcommand, *args
  end

  # Docker ANDs multiple `--filter label=` values, so matching both the current
  # and the pre-rename image title takes two commands rather than one filter
  # with two values. Without the legacy pass, `dash proxy remove` on a host that
  # has not yet been through the rename silently leaves the old container and
  # image behind. Stage 3d drops the legacy half.
  def remove_container
    combine \
      prune_containers_titled(Dash::Configuration::Proxy::IMAGE_TITLE),
      prune_containers_titled(Dash::Configuration::Proxy::LEGACY_IMAGE_TITLE)
  end

  def remove_image
    combine \
      prune_images_titled(Dash::Configuration::Proxy::IMAGE_TITLE),
      prune_images_titled(Dash::Configuration::Proxy::LEGACY_IMAGE_TITLE)
  end

  def cleanup_traefik
    chain \
      docker(:container, :stop, "traefik"),
      combine(
        docker(:container, :prune, "--force", "--filter", "label=org.opencontainers.image.title=Traefik"),
        docker(:image, :prune, "--all", "--force", "--filter", "label=org.opencontainers.image.title=Traefik")
      )
  end

  def ensure_proxy_directory
    make_directory config.proxy_boot.host_directory
  end

  def remove_proxy_directory
    remove_directory config.proxy_boot.host_directory
  end

  def ensure_apps_config_directory
    make_directory config.proxy_boot.apps_directory
  end

  # Static path rather than proxy_run_config.secrets_path: the file must be
  # removable precisely when the run config (or its secrets) is gone.
  def remove_proxy_secrets_file
    remove_file File.join(config.proxy_boot.host_directory, Dash::Configuration::Proxy::Run::SECRETS_FILENAME)
  end

  def boot_config
    [ :echo, "#{substitute(read_boot_options)} #{substitute(read_image)}:#{substitute(read_image_version)} #{substitute(read_run_command)}" ]
  end

  def read_boot_options
    read_file(config.proxy_boot.options_file, default: config.proxy_boot.default_boot_options.join(" "))
  end

  def read_image
    read_file(config.proxy_boot.image_file, default: config.proxy_boot.image_default)
  end

  def read_image_version
    read_file(config.proxy_boot.image_version_file, default: Dash::Configuration::Proxy::Run::MINIMUM_VERSION)
  end

  def read_run_command
    read_file(config.proxy_boot.run_command_file)
  end

  def reset_boot_options
    remove_file config.proxy_boot.options_file
  end

  def reset_image
    remove_file config.proxy_boot.image_file
  end

  def reset_image_version
    remove_file config.proxy_boot.image_version_file
  end

  def reset_run_command
    remove_file config.proxy_boot.run_command_file
  end

  def loadbalancer
    @loadbalancer ||= Dash::Commands::Loadbalancer.new(config, loadbalancer_config: DASH.loadbalancer_config)
  end

  private
    def container_name
      config.proxy_boot.container_name
    end

    def cert_store_volume_args
      [ "--volume", "dash-proxy-config:/home/dash-proxy/.config/dash-proxy" ]
    end

    # Same fallback as #pull: without a run config the image comes from the
    # legacy boot config files on the host.
    def one_off_image
      if proxy_run_config
        [ proxy_run_config.image ]
      else
        [ "#{substitute(read_image)}:#{substitute(read_image_version)}" ]
      end
    end

    def config_digest_label_args(digest)
      [ "--label", "#{CONFIG_DIGEST_LABEL}=#{digest}" ] if digest
    end

    def container_exists(name)
      docker :container, :inspect, name, ">", "/dev/null", "2>&1"
    end

    # Stage 3c. 3d deletes both of these with the rest of the bridge.
    def legacy_rename_marker
      File.join config.proxy_boot.host_directory, Dash::Configuration::Proxy::LEGACY_RENAME_MARKER
    end

    def mark_legacy_renamed
      combine \
        negate(container_exists(Dash::Configuration::Proxy::LEGACY_CONTAINER_NAME)),
        negate(container_exists(Dash::Configuration::Proxy::LEGACY_HOLDER_CONTAINER_NAME)),
        make_directory(config.proxy_boot.host_directory),
        [ :touch, legacy_rename_marker ]
    end

    # The image the volume copy borrows. The proxy this gem is pinned to is
    # already pulled by the time the copy runs, and `rake release` gates on
    # MINIMUM_VERSION being published, so this is always resolvable — unlike
    # the legacy boot path's image, which is read from a file on the host.
    def proxy_image
      proxy_run_config&.image ||
        "#{config.proxy_boot.image_default}:#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION}"
    end

    def prune_containers_titled(title)
      docker :container, :prune, "--force", "--filter", "label=org.opencontainers.image.title=#{title}"
    end

    def prune_images_titled(title)
      docker :image, :prune, "--all", "--force", "--filter", "label=org.opencontainers.image.title=#{title}"
    end

    def docker_run(digest: nil)
      docker \
        :run,
        "--name", container_name,
        "--network", "dash",
        "--detach",
        "--restart", "unless-stopped",
        "--volume", "dash-proxy-config:/home/dash-proxy/.config/dash-proxy",
        *config_digest_label_args(digest),
        *config.proxy_boot.apps_volume.docker_args
    end
end
