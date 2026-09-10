require "active_support/ordered_options"
require "active_support/core_ext/string/inquiry"
require "active_support/core_ext/module/delegation"
require "active_support/core_ext/hash/keys"
require "erb"
require "net/ssh/proxy/jump"

class Dash::Configuration
  HOOKS_OUTPUT_LEVELS = [ :quiet, :verbose ].freeze

  # The pre-3b name of #run_directory. Referenced only by the one-shot host
  # migration in Dash::Commands::Base; nothing reads paths under it.
  LEGACY_RUN_DIRECTORY = ".kamal"

  delegate :service, :labels, :hooks_path, to: :raw_config, allow_nil: true
  delegate :argumentize, :optionize, to: Dash::Utils

  attr_reader :destination, :raw_config, :secrets
  attr_reader :accessories, :aliases, :boot, :builder, :env, :logging, :output, :proxy, :proxy_boot, :report, :servers, :ssh, :sshkit, :registry

  include Validation

  class << self
    def create_from(config_file:, destination: nil, version: nil)
      ENV["DASH_DESTINATION"] = ENV["KAMAL_DESTINATION"] = destination

      raw_config = load_raw_config(config_file: config_file, destination: destination)

      new raw_config, destination: destination, version: version
    end

    def load_raw_config(config_file:, destination: nil)
      load_config_files(config_file, *destination_config_file(config_file, destination))
    end

    private
      def load_config_files(*files)
        files.inject({}) { |config, file| config.deep_merge! load_config_file(file) }
      end

      def load_config_file(file)
        if file.exist?
          # Newer Psych doesn't load aliases by default
          load_method = YAML.respond_to?(:unsafe_load) ? :unsafe_load : :load
          template = File.read(file)
          rendered = ERB.new(template, trim_mode: "-").result
          YAML.send(load_method, rendered).symbolize_keys
        else
          raise "Configuration file not found in #{file}"
        end
      end

      def destination_config_file(base_config_file, destination)
        base_config_file.sub_ext(".#{destination}.yml") if destination
      end
  end

  def initialize(raw_config, destination: nil, version: nil, validate: true)
    @raw_config = ActiveSupport::InheritableOptions.new(raw_config)
    @destination = destination
    @declared_version = version

    validate! raw_config, example: validation_yml.symbolize_keys, context: "", with: Dash::Configuration::Validator::Configuration

    @secrets = Dash::Secrets.new(destination: destination, secrets_path: secrets_path)

    # Eager load config to validate it, these are first as they have dependencies later on
    @servers = Servers.new(config: self)
    @registry = Registry.new(config: @raw_config, secrets: secrets)

    @accessories = @raw_config.accessories&.keys&.collect { |name| Accessory.new(name, config: self) } || []
    @aliases = @raw_config.aliases&.keys&.to_h { |name| [ name, Alias.new(name, config: self) ] } || {}
    @boot = Boot.new(config: self)
    @builder = Builder.new(config: self)
    @env = Env.new(config: @raw_config.env || {}, secrets: secrets)

    @logging = Logging.new(logging_config: @raw_config.logging)
    @output = Output.new(config: self)
    @report = Report.new(config: self)
    @proxy = Proxy.new(config: self, proxy_config: @raw_config.proxy, secrets: secrets)
    @proxy_boot = Proxy::Boot.new(config: self)
    @ssh = Ssh.new(config: self)
    @sshkit = Sshkit.new(config: self)

    ensure_destination_if_required
    ensure_required_keys_present
    ensure_valid_kamal_version
    ensure_retain_containers_valid
    ensure_valid_service_name
    ensure_no_traefik_reboot_hooks
    ensure_one_host_for_ssl_roles
    ensure_unique_hosts_for_ssl_roles
    ensure_local_registry_remote_builder_has_ssh_url
    ensure_no_conflicting_proxy_runs
    ensure_valid_loadbalancer
    ensure_valid_hooks_output!
    ensure_unproxied_roles_are_readiness_gated
    ensure_role_boot_can_pace_its_hosts
    ensure_boot_wait_paces_something
    ensure_rate_limit_can_identify_clients
    ensure_intercepted_errors_have_pages
    ensure_sleep_has_a_docker_socket
    ensure_proxy_protocol_names_its_peers
    ensure_max_idle_conns_meaningful
  end

  # Resolves every secret the deploy will need so a missing secret fails fast,
  # before any registry login or SSH connection. Secret adapters run here
  # instead of mid-deploy — same work, done earlier.
  def validate_secrets!(include_accessories: false)
    registry.username
    registry.password
    builder.secrets

    roles.each do |role|
      role.secrets_io(role.hosts.first) if role.hosts.any?

      if role.running_proxy?
        role.proxy.run&.secrets_io

        if role.proxy.custom_ssl_certificate?
          role.proxy.certificate_pem_content
          role.proxy.private_key_pem_content
        end
      end
    end

    accessories.each(&:secrets_io) if include_accessories

    true
  end

  def version=(version)
    @declared_version = version
  end

  def version
    @declared_version.presence || ENV["VERSION"] || git_version
  end

  def abbreviated_version
    if version
      # Don't abbreviate <sha>_uncommitted_<etc>
      if version.include?("_")
        version
      else
        version[0...7]
      end
    end
  end

  def minimum_version
    raw_config.minimum_version
  end

  def service_and_destination
    [ service, destination ].compact.join("-")
  end

  def roles
    servers.roles
  end

  def role(name)
    roles.detect { |r| r.name == name.to_s }
  end

  def accessory(name)
    accessories.detect { |a| a.name == name.to_s }
  end

  def all_hosts
    (roles + accessories).flat_map(&:hosts).uniq
  end

  def host_roles(host)
    roles.select { |role| role.hosts.include?(host) }
  end

  # Whether app commands iterate role-first. A role pacing its own hosts needs that: the
  # host-first branch of on_roles has no per-role runner to hand boot options to. Setting
  # `boot` on a role only overrides an unset parallel_roles — an explicit false conflicts
  # and is rejected in ensure_role_boot_can_pace_its_hosts.
  def parallel_roles?
    !!(boot.parallel_roles || roles.any?(&:boot))
  end

  def host_accessories(host)
    accessories.select { |accessory| accessory.hosts.include?(host) }
  end

  def app_hosts
    roles.flat_map(&:hosts).uniq
  end

  def primary_host
    primary_role&.primary_host
  end

  def primary_role_name
    raw_config.primary_role || "web"
  end

  def primary_role
    role(primary_role_name)
  end

  def allow_empty_roles?
    raw_config.allow_empty_roles
  end

  def proxy_roles
    roles.select(&:running_proxy?)
  end

  def load_balancing?
    proxy&.load_balancing?
  end

  def proxy_role_names
    proxy_roles.flat_map(&:name)
  end

  def proxy_accessories
    accessories.select(&:running_proxy?)
  end

  def proxy_hosts
    (proxy_roles.flat_map(&:hosts) + proxy_accessories.flat_map(&:hosts)).uniq
  end

  def image
    name = raw_config&.image.presence
    name ||= raw_config&.service if registry.local?

    name
  end

  def proxy_run(host)
    # We validate that all the config are identical for a host
    proxy_runs(host.to_s).first
  end

  def repository
    [ registry.server, image ].compact.join("/")
  end

  def absolute_image
    "#{repository}:#{version}"
  end

  def latest_image
    "#{repository}:#{latest_tag}"
  end

  def latest_tag
    [ "latest", *destination ].join("-")
  end

  def service_with_version
    "#{service}-#{version}"
  end

  def require_destination?
    raw_config.require_destination
  end

  def retain_containers
    raw_config.retain_containers || 5
  end

  def volume_args
    if raw_config.volumes.present?
      argumentize "--volume", raw_config.volumes
    else
      []
    end
  end

  def logging_args
    logging.args
  end

  def readiness_delay
    raw_config.readiness_delay || 7
  end

  def deploy_timeout
    raw_config.deploy_timeout || 30
  end

  def drain_timeout
    raw_config.drain_timeout || 30
  end

  def stop_timeout
    raw_config.stop_timeout
  end

  # Where dash keeps its per-host state - app env and assets, the proxy's
  # options/image/run_command files and apps-config bind mount, loadbalancer
  # service claims, deploy locks and the audit log - under the SSH user's home.
  # Renamed from `.kamal` in stage 3b of the server artifact rename
  # (zoolutions/dash#118); hosts still on the old name are migrated in place by
  # Dash::Commands::Base#ensure_run_directory.
  def run_directory
    ".dash"
  end

  def apps_directory
    File.join run_directory, "apps"
  end

  def app_directory
    File.join apps_directory, service_and_destination
  end

  def env_directory
    File.join app_directory, "env"
  end

  def assets_directory
    File.join app_directory, "assets"
  end

  def hooks_path
    raw_config.hooks_path || Dash::ProjectDirectory.join("hooks")
  end

  def secrets_path
    raw_config.secrets_path || Dash::ProjectDirectory.join("secrets")
  end

  def asset_path
    raw_config.asset_path
  end

  def error_pages_path
    raw_config.error_pages_path
  end

  def env_tags
    @env_tags ||= if (tags = raw_config.env["tags"])
      tags.collect { |name, config| Env::Tag.new(name, config: config, secrets: secrets) }
    else
      []
    end
  end

  def env_tag(name)
    env_tags.detect { |t| t.name == name.to_s }
  end

  def hooks_output_for(hook)
    case raw_config.hooks_output
    when Symbol, String
      raw_config.hooks_output.to_sym
    when Hash
      raw_config.hooks_output[hook]&.to_sym
    end
  end

  def to_h
    {
      roles: role_names,
      hosts: all_hosts,
      primary_host: primary_host,
      version: version,
      repository: repository,
      absolute_image: absolute_image,
      service_with_version: service_with_version,
      volume_args: volume_args,
      ssh_options: ssh.to_h,
      sshkit: sshkit.to_h,
      builder: builder.to_h,
      accessories: raw_config.accessories,
      logging: logging_args
    }.compact
  end

  private
    # Will raise ArgumentError if any required config keys are missing
    def ensure_destination_if_required
      if require_destination? && destination.nil?
        raise ArgumentError, "You must specify a destination"
      end

      true
    end

    def ensure_required_keys_present
      %i[ service registry ].each do |key|
        raise Dash::ConfigurationError, "Missing required configuration for #{key}" unless raw_config[key].present?
      end

      raise Dash::ConfigurationError, "Missing required configuration for image" if image.blank?

      if raw_config.servers.nil?
        raise Dash::ConfigurationError, "No servers or accessories specified" unless raw_config.accessories.present?
      else
        unless role(primary_role_name).present?
          raise Dash::ConfigurationError, "The primary_role #{primary_role_name} isn't defined"
        end

        if primary_role.hosts.empty?
          raise Dash::ConfigurationError, "No servers specified for the #{primary_role.name} primary_role"
        end

        unless allow_empty_roles?
          roles.each do |role|
            if role.hosts.empty?
              raise Dash::ConfigurationError, "No servers specified for the #{role.name} role. You can ignore this with allow_empty_roles: true"
            end
          end
        end
      end

      true
    end

    def ensure_valid_service_name
      raise Dash::ConfigurationError, "Service name can only include alphanumeric characters, hyphens, and underscores" unless raw_config[:service] =~ /^[a-z0-9_-]+$/i

      true
    end

    def ensure_valid_kamal_version
      if minimum_version && Gem::Version.new(minimum_version) > Gem::Version.new(Dash::VERSION)
        raise Dash::ConfigurationError, "Current version is #{Dash::VERSION}, minimum required is #{minimum_version}"
      end

      true
    end

    def ensure_retain_containers_valid
      raise Dash::ConfigurationError, "Must retain at least 1 container" if retain_containers < 1

      true
    end

    def ensure_no_traefik_reboot_hooks
      hooks = %w[ pre-traefik-reboot post-traefik-reboot ].select { |hook_file| File.exist?(File.join(hooks_path, hook_file)) }

      if hooks.any?
        raise Dash::ConfigurationError, "Found #{hooks.join(", ")}, these should be renamed to (pre|post)-proxy-reboot"
      end

      true
    end

    def ensure_one_host_for_ssl_roles
      roles.each(&:ensure_one_host_for_ssl)

      true
    end

    # A role without a proxy and without a healthcheck has no readiness gate: the deploy
    # accepts the container as ready once it is merely still running after readiness_delay,
    # then stops the old one. Warn-only for now so existing configs keep deploying.
    def ensure_unproxied_roles_are_readiness_gated
      offenders = roles.reject { |role| role.hosts.empty? || role.running_proxy? || role.readiness_gated? }
      return true if offenders.empty?

      warn "Non-proxied role(s) #{offenders.map(&:name).join(", ")} have no healthcheck. " \
        "Without one, dash accepts the container as ready #{readiness_delay}s after it merely starts " \
        "and then stops the previous container — traffic can be dropped. Add a `healthcheck:` block, " \
        "or opt out explicitly with `healthcheck: false`. This warning will become an error in a future release."

      true
    end

    # A PROXY protocol header rewrites the connecting address, which is the one
    # thing on a request nothing else can influence — and the one every access
    # control decision keys on. Honouring it from any peer that can reach the
    # port hands that address to whoever asks. Warn rather than raise: a proxy on
    # a private network with no other route in is a legitimate configuration.
    def ensure_proxy_protocol_names_its_peers
      offenders = all_hosts.select { |host| proxy_run(host)&.proxy_protocol_unrestricted? }
      return true if offenders.empty?

      warn "Host(s) #{offenders.sort.join(", ")}: proxy_protocol is enabled without proxy_protocol_allow_ips, " \
        "so dash-proxy honours a PROXY header from any peer that can reach the port. That header sets the client " \
        "address `allow_ips`, `rate_limit` and the access log all use. Name the load balancers you actually run."

      true
    end

    # Scale-to-zero is a deploy-time setting with a boot-time prerequisite: the
    # proxy can only stop and start containers through the runtime socket, and it
    # is only mounted when proxy/run/docker_socket names it. Without that, the
    # first request after an idle period hangs until wake_timeout and 503s, which
    # reads as a broken proxy rather than as a missing key. Say the key instead.
    #
    # Checked here rather than in Validator::Proxy because a role may carry
    # `sleep` while the root carries the socket — role.proxy is the merged view,
    # the validator only ever sees one side.
    def ensure_sleep_has_a_docker_socket
      offenders = roles.select do |role|
        next false unless role.running_proxy?

        role.proxy.proxy_config.dig("sleep", "after").present? && role.proxy.run&.docker_socket.blank?
      end

      return true if offenders.empty?

      raise Dash::ConfigurationError, "Role(s) #{offenders.map(&:name).join(", ")}: " \
        "proxy/sleep requires proxy/run/docker_socket - dash-proxy can only stop and start containers " \
        "through the container runtime socket, and it is not mounted into the proxy without it"
    end

    # dash-proxy resolves a zero max_idle_conns to its default of 100
    # (target_pool.go resolves defaults from zeros), so the one value an
    # operator writes to mean "keep none" is the one value that cannot mean it.
    # Legal, so warn rather than raise.
    def ensure_max_idle_conns_meaningful
      offenders = roles.select do |role|
        role.running_proxy? && role.proxy.proxy_config.dig("target", "max_idle_conns") == 0
      end
      return true if offenders.empty?

      warn "Role(s) #{offenders.map(&:name).join(", ")}: target/max_idle_conns: 0 means the proxy default of 100, " \
        "not \"keep none\" - dash-proxy resolves its defaults from zeros. Leave it unset for the default, " \
        "or set 1 for the practical minimum."

      true
    end

    # `intercept_errors` discards the app's error body and renders the proxy's own
    # page instead. With no pages to render, dash-proxy falls back to a bare
    # plaintext status line — so the app's error page is thrown away and replaced
    # by the words "Bad Gateway". Legal, and almost never the intent.
    def ensure_intercepted_errors_have_pages
      return true if error_pages_path.present?

      offenders = roles.select { |role| role.running_proxy? && role.proxy.proxy_config["intercept_errors"].present? }
      return true if offenders.empty?

      warn "Role(s) #{offenders.map(&:name).join(", ")}: intercept_errors is set but no error_pages_path is " \
        "configured, so dash-proxy replaces the app's error page with a bare plaintext status line. " \
        "Set `error_pages_path:` to serve your own pages, or remove `intercept_errors` to let the app's through."

      true
    end

    # Rate limiting and IP deny rules are only as correct as the address they key
    # on. `forward_headers: true` says something sits in front of the proxy, and
    # without `trusted_proxies` dash-proxy keys on that something's address
    # rather than the client's — so the limiter throttles the whole world as one
    # client (or nobody), and a deny list denies nobody it was written for. Warn
    # rather than raise: the config is legal, just almost certainly not what was
    # meant. (deny_user_agents is absent here on purpose — a User-Agent match
    # never keys on the client address.)
    def ensure_rate_limit_can_identify_clients
      offenders = roles.filter_map do |role|
        next unless role.running_proxy?

        proxy_config = role.proxy.proxy_config
        next unless proxy_config["forward_headers"] &&
          Array(proxy_config.dig("client_ip", "trusted_proxies")).empty?

        features = []
        features << "rate_limit" if proxy_config.dig("rate_limit", "requests").present?
        features << "deny_ips" if proxy_config["deny_ips"].present?

        [ role.name, features ] if features.any?
      end

      return true if offenders.empty?

      offenders.each do |role_name, features|
        warn "Role #{role_name}: #{features.join(" and ")} is set with forward_headers, " \
          "but no proxy/client_ip/trusted_proxies. dash-proxy will key on the address of " \
          "whatever sits in front of it, not on the client's — so the rules apply to every " \
          "visitor as one client, or to none of them. Declare the proxies in front with " \
          "`client_ip: trusted_proxies:`."
      end

      true
    end

    # `parallel_roles: false` iterates host-first, running each host's roles one after
    # another inside a single per-host thread. There is no per-role runner there to pace,
    # so the two keys cannot both be honoured — say which one to drop rather than quietly
    # ignoring either.
    def ensure_role_boot_can_pace_its_hosts
      # select, not find: this is also where every role-scoped Boot gets built, so a bad
      # one raises here rather than partway through a deploy.
      paced = roles.select(&:boot)
      return true if paced.empty? || boot.parallel_roles != false

      raise Dash::ConfigurationError, "servers/#{paced.first.name}/boot cannot be combined with boot/parallel_roles: false, " \
        "which boots each host's roles in turn and so cannot pace one role's hosts. Remove one of them"
    end

    # `wait` only ever fills the gap between one group of hosts and the next, and without a
    # `limit` or a `canary` there are no gaps — every host boots in one group. Before #47 that silently
    # cost a deploy one `wait` interval; now it silently does nothing at all. Either way the
    # operator asked for staggering and is not getting it, so say so.
    def ensure_boot_wait_paces_something
      offenders = [ [ "boot", boot ], *roles.filter_map { |role| [ "servers/#{role.name}/boot", role.boot ] if role.boot } ]
        .select { |_context, boot_config| boot_config.wait.present? && !boot_config.groups? }

      offenders.each do |context, boot_config|
        warn "#{context}/wait is set to #{boot_config.wait} but #{context}/limit is not, so it does nothing. " \
          "`wait` paces one group of hosts against the next, and without a limit every host boots in a single group. " \
          "Set `#{context}/limit` or `#{context}/canary` to stagger the boot, or remove `#{context}/wait`."
      end

      true
    end

    def ensure_unique_hosts_for_ssl_roles
      hosts = roles.select(&:ssl?).flat_map { |role| role.proxy.hosts }
      duplicates = hosts.tally.filter_map { |host, count| host if count > 1 }

      raise Dash::ConfigurationError, "Different roles can't share the same host for SSL: #{duplicates.join(", ")}" if duplicates.any?

      true
    end

    def ensure_local_registry_remote_builder_has_ssh_url
      if registry.local? && builder.remote?
        unless URI(builder.remote).scheme == "ssh"
          raise Dash::ConfigurationError, "Local registry with remote builder requires an SSH URL (e.g., ssh://user@host)"
        end
      end

      true
    end

    def ensure_no_conflicting_proxy_runs
      all_hosts.each do |host|
        run_configs = proxy_runs(host)
        if run_configs.uniq.size > 1
          raise Dash::ConfigurationError, "Conflicting proxy run configurations for host #{host}"
        end
      end
    end

    def proxy_runs(host)
      (host_roles(host) + host_accessories(host)).map(&:proxy).compact.map(&:run).compact
    end

    # `loadbalancer: true` resolves to the primary role's first host, so an
    # accessories-only configuration has nothing to run it on.
    def ensure_valid_loadbalancer
      if proxy.loadbalancer == true && primary_role.nil?
        raise Dash::ConfigurationError, "proxy/loadbalancer: can't be enabled without servers"
      end

      true
    end

    def role_names
      raw_config.servers.is_a?(Array) ? [ "web" ] : raw_config.servers.keys.sort
    end

    def ensure_valid_hooks_output!
      case raw_config.hooks_output
      when Symbol, String
        validate_hooks_output_level!(raw_config.hooks_output.to_sym)
      when Hash
        raw_config.hooks_output.each { |hook, level| validate_hooks_output_level!(level.to_sym, hook) }
      end
    end

    def validate_hooks_output_level!(level, hook = nil)
      return if HOOKS_OUTPUT_LEVELS.include?(level)
      context = hook ? " for hook '#{hook}'" : ""
      raise Dash::ConfigurationError, "Invalid hooks_output '#{level}'#{context}, must be one of: #{HOOKS_OUTPUT_LEVELS.join(', ')}"
    end

    def git_version
      @git_version ||=
        if Dash::Git.used?
          if Dash::Git.uncommitted_changes.present? && !builder.git_clone?
            uncommitted_suffix = "_uncommitted_#{SecureRandom.hex(8)}"
          end
          [ Dash::Git.revision, uncommitted_suffix ].compact.join
        else
          raise "Can't use commit hash as version, no git repository found in #{Dir.pwd}"
        end
    end
end
