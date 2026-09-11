class Dash::Commands::App < Dash::Commands::Base
  include Assets, Containers, ErrorPages, Execution, Images, Logging, Proxy

  ACTIVE_DOCKER_STATUSES = [ :running, :restarting ]

  # Separates the two answers #boot_state returns. A container id is hex and a version is
  # a name suffix, so neither can produce this line on its own.
  BOOT_STATE_SEPARATOR = "--%--"

  attr_reader :role, :host

  delegate :container_name, to: :role

  def initialize(config, role: nil, host: nil)
    super(config)
    @role = role
    @host = host
  end

  def run(hostname: nil)
    docker :run,
      "--detach",
      "--restart", role.restart_policy,
      "--name", container_name,
      "--network", "dash",
      *([ "--hostname", hostname ] if hostname),
      "--env", "KAMAL_CONTAINER_NAME=\"#{container_name}\"",
      "--env", "KAMAL_VERSION=\"#{config.version}\"",
      "--env", "KAMAL_HOST=\"#{host}\"",
      *([ "--env", "KAMAL_DESTINATION=\"#{config.destination}\"" ] if config.destination),
      *role.env_args(host),
      *role.logging_args,
      *config.volume_args,
      *role.asset_volume_args,
      *role.label_args,
      *role.option_args,
      *role.healthcheck_args,
      config.absolute_image,
      role.cmd
  end

  def start
    docker :start, container_name
  end

  def status(version:)
    pipe container_id_for_version(version), xargs(docker(:inspect, "--format", DOCKER_HEALTH_STATUS_FORMAT))
  end

  # The `healthcheck: exec:` probe, run from the deploy host against the container that is
  # booting. Single-quoted by #shell, so the command expands inside the container rather
  # than in the deploy host's shell. Non-zero exit means not ready.
  def health_probe(version:)
    docker :exec, container_name(version), *shell([ role.healthcheck.exec ])
  end

  def stop(version: nil)
    pipe \
      version ? container_id_for_version(version) : current_running_container_id,
      xargs(docker(:stop, *role.stop_args))
  end

  def info
    docker :ps, *container_filter_args
  end


  def current_running_container_id
    current_running_container(format: "--quiet")
  end

  def container_id_for_version(version, only_running: false)
    container_id_for(container_name: container_name(version), only_running: only_running)
  end

  def current_running_version
    pipe \
      current_running_container(format: "--format '{{.Names}}'"),
      extract_version_from_name
  end

  # Everything a boot needs to know about a host before it starts anything: whether a
  # container for the version being deployed already exists (so it can be renamed out of
  # the way) and which version is running now (so it can be stopped once the new one is
  # live). Two questions, one round trip, answers split on BOOT_STATE_SEPARATOR.
  #
  # Chained with `;` rather than `&&`: an empty answer to either is a normal result, not
  # a failure, and the second question must be asked whatever the first one said.
  def boot_state(version)
    chain \
      container_id_for_version(version),
      [ :echo, BOOT_STATE_SEPARATOR ],
      current_running_version
  end

  def list_versions(*docker_args, statuses: nil)
    pipe \
      docker(:ps, *container_filter_args(statuses: statuses), *docker_args, "--format", '"{{.Names}}"'),
      extract_version_from_name
  end

  def ensure_env_directory
    make_directory role.env_directory
  end

  private
    def latest_image_id
      docker :image, :ls, *argumentize("--filter", "reference=#{config.latest_image}"), "--format", "'{{.ID}}'"
    end

    def current_running_container(format:)
      pipe \
        shell(chain(latest_image_container(format: format), latest_container(format: format))),
        [ :head, "-1" ]
    end

    def latest_image_container(format:)
      latest_container format: format, filters: [ "ancestor=$(#{latest_image_id.join(" ")})" ]
    end

    def latest_container(format:, filters: nil)
      docker :ps, "--latest", *format, *container_filter_args(statuses: ACTIVE_DOCKER_STATUSES), argumentize("--filter", filters)
    end

    def container_filter_args(statuses: nil)
      argumentize "--filter", container_filters(statuses: statuses)
    end

    def image_filter_args
      argumentize "--filter", image_filters
    end

    def extract_version_from_name
      # Extract SHA from "service-role-dest-SHA"
      %(while read line; do echo ${line##{role.container_prefix}-}; done)
    end

    def container_filters(statuses: nil)
      [ "label=service=#{config.service}" ].tap do |filters|
        filters << "label=destination=#{config.destination}"
        filters << "label=role=#{role}" if role
        statuses&.each do |status|
          filters << "status=#{status}"
        end
      end
    end

    def image_filters
      [ "label=service=#{config.service}" ]
    end
end
