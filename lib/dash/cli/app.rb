class Dash::Cli::App < Dash::Cli::Base
  desc "boot", "Boot app on servers (or reboot app if already running)"
  def boot
    modify(lock: true) do
      say "Get most recent version available as an image...", :magenta unless options[:version]
      using_version(version_or_latest) do |version|
        say "Start container with version #{version} (or reboot if already running)...", :magenta

        # Assets are prepared in a separate step to ensure they are on all hosts before booting
        on(DASH.app_hosts) do
          Dash::Cli::App::ErrorPages.new(host, self).run

          DASH.roles_on(host).each do |role|
            Dash::Cli::App::Assets.new(host, role, self).run
            Dash::Cli::App::SslCertificates.new(host, role, self).run
          end
        end

        # Primary hosts and roles are returned first, so they can open the barrier
        barrier = Dash::Cli::Healthcheck::Barrier.new
        cli = self

        boot_groups = host_boot_groups

        boot_groups.each_with_index do |hosts, index|
          host_list = Array(hosts).join(",")
          run_hook "pre-app-boot", hosts: host_list

          on_roles(DASH.roles, hosts: hosts, parallel: DASH.config.parallel_roles?, rolling: true) do |host, role|
            Dash::Cli::App::Boot.new(host, role, self, version, barrier, cli).run
          end

          run_hook "post-app-boot", hosts: host_list

          # `wait` paces one group against the next, so the last group has nothing to pace
          # against. Without a `limit` there is only ever one group, and waiting at all
          # would be a fixed delay on every deploy buying no staggering.
          sleep DASH.config.boot.wait if DASH.config.boot.wait && index < boot_groups.size - 1
        end

        # Tag once the app booted on all hosts
        on(DASH.app_hosts) do |host|
          execute *DASH.auditor.record_then("Tagging #{DASH.config.absolute_image} as the latest image",
            DASH.app.tag_latest_image)
        end
      end
    end
  end

  desc "start", "Start existing app container on servers"
  def start
    modify(lock: true) do
      cli = self

      on_roles(DASH.roles, hosts: DASH.app_hosts, parallel: DASH.config.parallel_roles?, rolling: true) do |host, role|
        app = DASH.app(role: role, host: host)
        execute *DASH.auditor.record("Started app version #{DASH.config.version}"), verbosity: :debug
        execute *app.start, raise_on_non_zero_exit: false

        if role.running_proxy?
          version = capture_with_info(*app.current_running_version, raise_on_non_zero_exit: false).strip
          endpoint = capture_with_info(*app.container_id_for_version(version)).strip
          raise Dash::Cli::BootError, "Failed to get endpoint for #{role} on #{host}, did the container boot?" if endpoint.empty?

          cli.run_hook "pre-proxy-deploy", hosts: host.to_s, role: role.name
          execute *app.deploy(target: endpoint)
          cli.run_hook "post-proxy-deploy", hosts: host.to_s, role: role.name
        end
      end
    end
  end

  desc "stop", "Stop app container on servers"
  def stop
    modify(lock: true) do
      on_roles(DASH.roles, hosts: DASH.app_hosts, parallel: DASH.config.parallel_roles?) do |host, role|
        app = DASH.app(role: role, host: host)
        execute *DASH.auditor.record("Stopped app", role: role), verbosity: :debug

        if role.running_proxy?
          version = capture_with_info(*app.current_running_version, raise_on_non_zero_exit: false).strip
          endpoint = capture_with_info(*app.container_id_for_version(version)).strip
          if endpoint.present?
            execute *app.remove, raise_on_non_zero_exit: false
          end
        end

        execute *app.stop, raise_on_non_zero_exit: false
      end
    end
  end

  # FIXME: Drop in favor of just containers?
  desc "details", "Show details about app containers"
  def details
    quiet = options[:quiet]
    on_roles(DASH.roles, hosts: DASH.app_hosts) do |host, role|
      puts_by_host host, capture_with_info(*DASH.app(role: role, host: host).info), quiet: quiet
    end
  end

  desc "exec [CMD...]", "Execute a custom command on servers within the app container (use --help to show options)"
  option :interactive, aliases: "-i", type: :boolean, default: false, desc: "Execute command over ssh for an interactive shell (use for console/bash)"
  option :reuse, type: :boolean, default: false, desc: "Reuse currently running container instead of starting a new one"
  option :env, aliases: "-e", type: :hash, desc: "Set environment variables for the command"
  option :detach, type: :boolean, default: false, desc: "Execute command in a detached container"
  option :raw, type: :boolean, default: false, desc: "Output raw, unmodified stdout"
  def exec(*cmd)
    raw = options[:raw]

    if (incompatible_options = [ :interactive, :reuse ].select { |key| options[:detach] && options[key] }.presence)
      raise ArgumentError, "Detach is not compatible with #{incompatible_options.join(" or ")}"
    end

    if raw && (incompatible_options = [ :interactive, :detach ].select { |key| options[key] }.presence)
      raise ArgumentError, "Raw is not compatible with #{incompatible_options.join(" or ")}"
    end

    if cmd.empty?
      raise ArgumentError, "No command provided. You must specify a command to execute."
    end

    with_raw_output(raw) do
      pre_connect_if_required

      cmd = Dash::Utils.join_commands(cmd)
      env = options[:env]
      detach = options[:detach]
      quiet = options[:quiet]
      case
      when options[:interactive] && options[:reuse]
        say "Get current version of running container...", :magenta unless options[:version]
        using_version(options[:version] || current_running_version) do |version|
          say "Launching interactive command with version #{version} via SSH from existing container on #{DASH.primary_host}...", :magenta
          run_locally { exec DASH.app(role: DASH.primary_role, host: DASH.primary_host).execute_in_existing_container_over_ssh(cmd, env: env) }
        end

      when options[:interactive]
        say "Get most recent version available as an image...", :magenta unless options[:version]
        using_version(version_or_latest) do |version|
          say "Launching interactive command with version #{version} via SSH from new container on #{DASH.primary_host}...", :magenta
          on(DASH.primary_host) { execute *DASH.registry.login }
          run_locally do
            exec DASH.app(role: DASH.primary_role, host: DASH.primary_host).execute_in_new_container_over_ssh(cmd, env: env)
          end
        end

      when options[:reuse]
        say "Get current version of running container...", :magenta unless options[:version]
        using_version(options[:version] || current_running_version) do |version|
          say "Launching command with version #{version} from existing container...", :magenta

          on_roles(DASH.roles, hosts: DASH.app_hosts) do |host, role|
            execute *DASH.auditor.record("Executed cmd '#{cmd}' on app version #{version}", role: role), verbosity: :debug
            puts_by_host host, capture_with_info(*DASH.app(role: role, host: host).execute_in_existing_container(cmd, env: env), strip: !raw), quiet: quiet, raw: raw
          end
        end

      else
        say "Get most recent version available as an image...", :magenta unless options[:version]
        using_version(version_or_latest) do |version|
          say "Launching command with version #{version} from new container...", :magenta
          on(DASH.app_hosts) { execute *DASH.registry.login }

          on_roles(DASH.roles, hosts: DASH.app_hosts) do |host, role|
            execute *DASH.auditor.record("Executed cmd '#{cmd}' on app version #{version}"), verbosity: :debug
            puts_by_host host, capture_with_info(*DASH.app(role: role, host: host).execute_in_new_container(cmd, env: env, detach: detach), strip: !raw), quiet: quiet, raw: raw
          end
        end
      end
    end
  end

  desc "containers", "Show app containers on servers"
  def containers
    quiet = options[:quiet]
    on(DASH.app_hosts) { |host| puts_by_host host, capture_with_info(*DASH.app.list_containers), quiet: quiet }
  end

  desc "stale_containers", "Detect app stale containers"
  option :stop, aliases: "-s", type: :boolean, default: false, desc: "Stop the stale containers found"
  def stale_containers
    quiet = options[:quiet]
    stop = options[:stop]

    with_lock_if_stopping do
      on_roles(DASH.roles, hosts: DASH.app_hosts) do |host, role|
        app = DASH.app(role: role, host: host)
        listed, running = Dash::Commands::App.split_state(capture_with_info(*app.stale_state, raise_on_non_zero_exit: false))
        versions = listed.strip.split("\n") - [ running.strip ]

        versions.each do |version|
          if stop
            puts_by_host host, "Stopping stale container for role #{role} with version #{version}", quiet: quiet
            execute *app.stop(version: version), raise_on_non_zero_exit: false
          else
            puts_by_host host,  "Detected stale container for role #{role} with version #{version} (use `dash app stale_containers --stop` to stop)", quiet: quiet
          end
        end
      end
    end
  end

  desc "images", "Show app images on servers"
  def images
    quiet = options[:quiet]
    on(DASH.app_hosts) { |host| puts_by_host host, capture_with_info(*DASH.app.list_images), quiet: quiet }
  end

  desc "logs", "Show log lines from app on servers (use --help to show options)"
  option :since, aliases: "-s", desc: "Show lines since timestamp (e.g. 2013-01-02T13:23:37Z) or relative (e.g. 42m for 42 minutes)"
  option :lines, type: :numeric, aliases: "-n", desc: "Number of lines to show from each server"
  option :grep, aliases: "-g", desc: "Show lines with grep match only (use this to fetch specific requests by id)"
  option :grep_options, desc: "Additional options supplied to grep"
  option :follow, aliases: "-f", desc: "Follow log on primary server (or specific host set by --hosts)"
  option :skip_timestamps, type: :boolean, aliases: "-T", desc: "Skip appending timestamps to logging output"
  option :container_id, desc: "Docker container ID to fetch logs"
  def logs
    # FIXME: Catch when app containers aren't running

    grep = options[:grep]
    grep_options = options[:grep_options]
    since = options[:since]
    container_id = options[:container_id]
    timestamps = !options[:skip_timestamps]
    quiet = options[:quiet]

    if options[:follow]
      lines = options[:lines].presence || ((since || grep) ? nil : 10) # Default to 10 lines if since or grep isn't set

      run_locally do
        info "Following logs on #{DASH.primary_host}..."

        DASH.specific_roles ||= [ DASH.primary_role.name ]
        role = DASH.roles_on(DASH.primary_host).first

        app = DASH.app(role: role, host: host)
        info app.follow_logs(host: DASH.primary_host, container_id: container_id, timestamps: timestamps, lines: lines, grep: grep, grep_options: grep_options)
        exec app.follow_logs(host: DASH.primary_host, container_id: container_id, timestamps: timestamps, lines: lines, grep: grep, grep_options: grep_options)
      end
    else
      lines = options[:lines].presence || ((since || grep) ? nil : 100) # Default to 100 lines if since or grep isn't set

      on_roles(DASH.roles, hosts: DASH.app_hosts) do |host, role|
        begin
          puts_by_host host, capture_with_info(*DASH.app(role: role, host: host).logs(container_id: container_id, timestamps: timestamps, since: since, lines: lines, grep: grep, grep_options: grep_options)), quiet: quiet
        rescue SSHKit::Command::Failed
          puts_by_host host, "Nothing found", quiet: quiet
        end
      end
    end
  end

  desc "remove", "Remove app containers and images from servers"
  def remove
    modify(lock: true) do
      stop
      remove_containers
      remove_images
      remove_app_directories
    end
  end

  desc "live", "Set the app to live mode"
  def live
    modify(lock: true) do
      on_roles(DASH.roles, hosts: DASH.proxy_hosts) do |host, role|
        execute *DASH.app(role: role, host: host).live if role.running_proxy?
      end
    end
  end

  desc "maintenance", "Set the app to maintenance mode"
  option :drain_timeout, type: :numeric, desc: "How long to allow in-flight requests to complete (defaults to drain_timeout from config)"
  option :message, type: :string, desc: "Message to display to clients while stopped"
  def maintenance
    maintenance_options = { drain_timeout: options[:drain_timeout] || DASH.config.drain_timeout, message: options[:message] }

    modify(lock: true) do
      on_roles(DASH.roles, hosts: DASH.proxy_hosts) do |host, role|
        execute *DASH.app(role: role, host: host).maintenance(**maintenance_options) if role.running_proxy?
      end
    end
  end

  desc "rollout <deploy|set|stop>", "Manage a canary rollout of a new version through dash-proxy"
  option :percent, type: :numeric, desc: "Percentage of traffic to send to the rollout target"
  option :list, type: :array, desc: "Send requests whose kamal-rollout cookie matches these values to the rollout target"
  def rollout(action)
    case action
    when "deploy" then start_rollout
    when "set"    then set_rollout
    when "stop"   then stop_rollout
    else raise ArgumentError, "Unknown rollout action '#{action}', expected deploy, set or stop"
    end
  end

  desc "remove_container [VERSION]", "Remove app container with given version from servers", hide: true
  def remove_container(version)
    modify(lock: true) do
      on_roles(DASH.roles, hosts: DASH.app_hosts) do |host, role|
        execute *DASH.auditor.record("Removed app container with version #{version}", role: role), verbosity: :debug
        execute *DASH.app(role: role, host: host).remove_container(version: version)
      end
    end
  end

  desc "remove_containers", "Remove all app containers from servers", hide: true
  def remove_containers
    modify(lock: true) do
      on_roles(DASH.roles, hosts: DASH.app_hosts) do |host, role|
        execute *DASH.auditor.record("Removed all app containers", role: role), verbosity: :debug
        execute *DASH.app(role: role, host: host).remove_containers
      end
    end
  end

  desc "remove_images", "Remove all app images from servers", hide: true
  def remove_images
    modify(lock: true) do
      on(hosts_removing_all_roles) do
        execute *DASH.auditor.record("Removed all app images"), verbosity: :debug
        execute *DASH.app.remove_images
      end
    end
  end

  desc "remove_app_directories", "Remove the app directories from servers", hide: true
  def remove_app_directories
    modify(lock: true) do
      on(hosts_removing_all_roles) do |host|
        execute *DASH.server.remove_app_directory, raise_on_non_zero_exit: false
        execute *DASH.auditor.record("Removed #{DASH.config.app_directory}"), verbosity: :debug
        execute *DASH.app.remove_proxy_app_directory, raise_on_non_zero_exit: false
      end
    end
  end

  desc "version", "Show app version currently running on servers"
  def version
    quiet = options[:quiet]
    on(DASH.app_hosts) do |host|
      role = DASH.roles_on(host).first
      puts_by_host host, capture_with_info(*DASH.app(role: role, host: host).current_running_version).strip, quiet: quiet
    end
  end

  private
    def start_rollout
      modify(lock: true) do
        say "Get most recent version available as an image...", :magenta unless options[:version]
        using_version(version_or_latest) do |version|
          say "Start rollout target with version #{version} alongside the live version...", :magenta

          on(DASH.proxy_hosts) do
            DASH.roles_on(host).each do |role|
              Dash::Cli::App::Assets.new(host, role, self).run if role.running_proxy?
            end
          end

          on_roles(DASH.roles, hosts: DASH.proxy_hosts, parallel: DASH.config.parallel_roles?, rolling: true) do |host, role|
            Dash::Cli::App::RolloutBoot.new(host, role, self, version).run if role.running_proxy?
          end
        end
      end
    end

    def set_rollout
      percent, list = options[:percent], options[:list]

      if percent.nil? && list.blank?
        raise ArgumentError, "No traffic split provided. You must specify --percent or --list."
      end

      modify(lock: true) do
        on_roles(DASH.roles, hosts: DASH.proxy_hosts) do |host, role|
          execute *DASH.app(role: role, host: host).rollout_set(percent: percent, list: list) if role.running_proxy?
        end
      end
    end

    def stop_rollout
      modify(lock: true) do
        on_roles(DASH.roles, hosts: DASH.proxy_hosts) do |host, role|
          execute *DASH.app(role: role, host: host).rollout_stop if role.running_proxy?
        end
      end
    end

    def hosts_removing_all_roles
      DASH.app_hosts.select { |host| DASH.roles_on(host).map(&:name).sort == DASH.config.host_roles(host.to_s).map(&:name).sort }
    end

    def using_version(new_version)
      if new_version
        begin
          old_version = DASH.config.version
          DASH.config.version = new_version
          yield new_version
        ensure
          DASH.config.version = old_version
        end
      else
        yield DASH.config.version
      end
    end

    def current_running_version(host: DASH.primary_host)
      version = nil
      on(host) do
        role = DASH.roles_on(host).first
        version = capture_with_info(*DASH.app(role: role, host: host).current_running_version).strip
      end
      version.presence
    end

    def version_or_latest
      options[:version] || DASH.config.latest_tag
    end

    def with_lock_if_stopping
      if options[:stop]
        modify(lock: true) { yield }
      else
        yield
      end
    end

    # Canary hosts each form a group of one and go first; whatever is left is sliced by
    # `limit` (a percentage counts those remaining hosts, the set it actually slices) or
    # boots as a single group. No canary and no limit is the one-group default.
    def host_boot_groups
      hosts = DASH.app_hosts
      canary_hosts = canary_boot_hosts(hosts)
      rest = hosts - canary_hosts
      limit = DASH.config.boot.limit_for(rest)

      rest_groups = limit ? rest.each_slice(limit).to_a : [ rest ]

      canary_hosts.map { |host| [ host ] } + rest_groups.reject(&:empty?)
    end

    # The first N primary-role hosts of this run. `--roles`/`--hosts` may leave none, in
    # which case there is nothing to prove ahead of the others and no canary group.
    def canary_boot_hosts(hosts)
      count = DASH.config.boot.canary
      count ? (DASH.primary_role.hosts & hosts).first(count) : []
    end
end
