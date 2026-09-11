require "active_support/core_ext/enumerable"
require "active_support/core_ext/module/delegation"
require "active_support/core_ext/object/blank"
require "active_support/broadcast_logger"
require "active_support/notifications"

class Dash::Commander
  attr_accessor :verbosity, :holding_lock, :holding_server_lock, :connected, :logging, :lock_wait, :lock_wait_timeout, :lock_wait_interval
  attr_reader :specific_roles, :specific_hosts, :timings, :report

  # Hosts whose run directory this process has already swept, so the second lock acquire
  # of a command does not re-run the migration everywhere. Per host rather than a flag:
  # `dash upgrade` narrows the host set between acquires, and a host that was never in
  # scope has never been swept.
  attr_reader :run_directory_ensured_on
  delegate :hosts, :roles, :primary_host, :primary_role, :roles_on, :app_hosts, :proxy_hosts, :accessory_hosts, to: :specifics

  def initialize
    reset
  end

  def reset
    self.verbosity = :info
    self.holding_lock = env_flag("DASH_LOCK", "KAMAL_LOCK")
    self.holding_server_lock = env_flag("DASH_SERVER_LOCK", "KAMAL_SERVER_LOCK")
    self.connected = false
    self.logging = false
    self.lock_wait = false
    self.lock_wait_timeout = 900
    self.lock_wait_interval = 15
    @modify_depth = 0
    @timings = Dash::Timings.new
    @report = Dash::Report.new(timings: @timings)
    @specifics = @specific_roles = @specific_hosts = nil
    @config = @config_kwargs = nil
    @output_logger = nil
    @commands = {}
    @run_directory_ensured_on = []
  end

  def config
    @config ||= Dash::Configuration.create_from(**@config_kwargs.to_h).tap do |config|
      @config_kwargs = nil
      configure_sshkit_with(config)
    end
  end

  def configure(**kwargs)
    @config, @config_kwargs = nil, kwargs
  end

  def configured?
    @config || @config_kwargs
  end

  def specific_primary!
    @specifics = nil
    if specific_roles.present?
      self.specific_hosts = [ specific_roles.first.primary_host ]
    else
      self.specific_hosts = [ config.primary_host ]
    end
  end

  def specific_roles=(role_names)
    @specifics = nil
    @specific_roles = if role_names.present?
      filtered = Dash::Utils.filter_specific_items(role_names, config.roles)
      raise ArgumentError, "No --roles match for #{role_names.join(',')}" if filtered.empty?
      filtered
    end
  end

  def specific_hosts=(hosts)
    @specifics = nil
    @specific_hosts = if hosts.present?
      filtered = Dash::Utils.filter_specific_items(hosts, config.all_hosts)
      raise ArgumentError, "No --hosts match for #{hosts.join(',')}" if filtered.empty?
      filtered
    end
  end

  def with_specific_hosts(hosts)
    original_hosts, self.specific_hosts = specific_hosts, hosts
    yield
  ensure
    self.specific_hosts = original_hosts
  end

  def accessory_names
    config.accessories&.collect(&:name) || []
  end

  def app(role: nil, host: nil)
    Dash::Commands::App.new(config, role: role, host: host)
  end

  def accessory(name)
    Dash::Commands::Accessory.new(config, name: name)
  end

  def auditor(**details)
    Dash::Commands::Auditor.new(config, **details)
  end

  def builder
    @commands[:builder] ||= Dash::Commands::Builder.new(config)
  end

  def docker
    @commands[:docker] ||= Dash::Commands::Docker.new(config)
  end

  def hook
    @commands[:hook] ||= Dash::Commands::Hook.new(config)
  end

  def lock
    @commands[:lock] ||= Dash::Commands::Lock.new(config)
  end

  # Guards the dash-proxy container, which a host runs once for every
  # destination deployed onto it. Every destination contends for this one.
  def server_lock
    @commands[:server_lock] ||= Dash::Commands::Lock.new(config, scope: :server)
  end

  def proxy(host)
    Dash::Commands::Proxy.new(config, host: host)
  end

  def loadbalancer_config
    @loadbalancer_config ||= Dash::Configuration::Loadbalancer.new(config: config, proxy_config: config.proxy.proxy_config, secrets: config.secrets)
  end

  def loadbalancer
    @commands[:loadbalancer] ||= Dash::Commands::Loadbalancer.new(config, loadbalancer_config: loadbalancer_config)
  end

  def prune
    @commands[:prune] ||= Dash::Commands::Prune.new(config)
  end

  def registry
    @commands[:registry] ||= Dash::Commands::Registry.new(config)
  end

  def server
    @commands[:server] ||= Dash::Commands::Server.new(config)
  end

  def alias(name)
    config.aliases[name]
  end

  def resolve_alias(name)
    if @config
      @config.aliases[name]&.command
    else
      raw_config = Dash::Configuration.load_raw_config(**@config_kwargs.to_h.slice(:config_file, :destination))
      raw_config[:aliases]&.dig(name)
    end
  end

  def with_verbosity(level)
    old_level = self.verbosity

    self.verbosity = level
    SSHKit.config.output_verbosity = level

    yield
  ensure
    self.verbosity = old_level
    SSHKit.config.output_verbosity = old_level
  end

  def modify(command:, subcommand:)
    @logging = true
    if modify_started
      ActiveSupport::Notifications.instrument("modify.kamal",
        command: command, subcommand: subcommand, destination: config.destination, hosts: hosts, report: report) { yield }
    else
      yield
    end
  ensure
    output_logger.close if modify_finished
  end

  def log(line)
    output_logger << "#{line}\n" if logging
  end

  def holding_server_lock?
    self.holding_server_lock
  end

  def holding_lock?
    self.holding_lock
  end

  def connected?
    self.connected
  end

  private
    def output_logger
      @output_logger ||= ActiveSupport::BroadcastLogger.new
    end

    def modify_started
      @modify_depth += 1
      @modify_depth == 1
    end

    def modify_finished
      @modify_depth -= 1
      @modify_depth == 0
    end

    # Lazy setup of SSHKit
    def configure_sshkit_with(config)
      SSHKit::Backend::Netssh.pool.idle_timeout = config.sshkit.pool_idle_timeout
      SSHKit::Backend::Netssh.configure do |sshkit|
        sshkit.max_concurrent_starts = config.sshkit.max_concurrent_starts
        sshkit.dns_retries = config.sshkit.dns_retries
        sshkit.ssh_options = config.ssh.options
      end
      SSHKit.config.command_map[:docker] = "docker" # No need to use /usr/bin/env, just clogs up the logs
      SSHKit.config.output_verbosity = verbosity

      configure_output_with(config)
    end

    def configure_output_with(config)
      return unless config.output.enabled?

      config.output.loggers.each { |logger| output_logger.broadcast_to(logger) }

      SSHKit.config.output = Dash::Output::Formatter.new($stdout, output_logger)

      at_exit { @output_logger&.close }
    rescue => e
      $stderr.puts "Output logger setup failed: #{e.class}: #{e.message}"
      $stderr.puts e.backtrace.join("\n") if ENV["VERBOSE"]
    end

    def specifics
      @specifics ||= Dash::Commander::Specifics.new(config, specific_hosts, specific_roles)
    end

    # First name that is set wins, so DASH_* takes precedence over the legacy
    # KAMAL_* twin rather than either one merely being truthy. Dash::Tags#env
    # writes both with the same value, so they only disagree when an operator
    # sets one by hand.
    def env_flag(*names)
      names.filter_map { |name| ENV[name] }.first == "true"
    end
end
