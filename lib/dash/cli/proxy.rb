class Dash::Cli::Proxy < Dash::Cli::Base
  desc "boot", "Boot proxy on servers"
  def boot
    modify(lock: true, server_lock: true) do
      on(network_hosts) do |host|
        execute *DASH.docker.create_network
      rescue SSHKit::Command::Failed => e
        raise unless e.message.include?("already exists")
      end

      # Skip proxy on loadbalancer host - the loadbalancer will handle it
      proxy_hosts = DASH.proxy_hosts
      if DASH.config.proxy.loadbalancer_on_proxy_host?
        proxy_hosts = proxy_hosts - [ DASH.config.proxy.effective_loadbalancer ]
      end

      drifted_hosts = Concurrent::Array.new
      stale_hosts = Concurrent::Array.new
      auto_reboot = DASH.config.proxy.reboot_on_deploy?

      on(proxy_hosts) do |host|
        execute *DASH.registry.login

        # Before anything reads the new container, volume or network: bring a
        # host still on pre-rename identity across, and make the apps-config
        # directory in the same round trip. Nothing but a `test -f` once it has
        # been - see Dash::Cli::Proxy::LegacyRename.
        Dash::Cli::Proxy::LegacyRename.new(host, self).run

        proxy = DASH.proxy(host)
        drift = Dash::Cli::Proxy::Drift.new(host, self)

        if drift.drifted? && auto_reboot
          # Leave the old proxy serving until its serial reboot slot below.
          drifted_hosts << host.to_s
        else
          stale_hosts << host.to_s if drift.drifted?

          # The tag off the inspect the drift check already made, not a read of its own.
          version = drift.version

          if version && Dash::Utils.older_version?(version, Dash::Configuration::Proxy::Run::MINIMUM_VERSION)
            raise "dash-proxy version #{version} is too old, run `dash proxy reboot` in order to update to at least #{Dash::Configuration::Proxy::Run::MINIMUM_VERSION}"
          end

          if (run_config = proxy.proxy_run_config)&.secrets?
            execute *proxy.ensure_proxy_directory
            upload! run_config.secrets_io, run_config.secrets_path, mode: "0600"
          else
            # A host keeps no secrets it no longer needs.
            execute *proxy.remove_proxy_secrets_file, raise_on_non_zero_exit: false
          end

          execute *proxy.start_holder_or_run if proxy.port_holder?
          execute *proxy.start_or_run(digest: drift.expected_digest)
        end
      end

      if stale_hosts.any?
        say "dash-proxy on #{stale_hosts.sort.join(", ")} is running with a configuration that no longer matches the deploy config. " \
            "Automatic reboot is disabled (proxy: reboot_on_deploy: false) - run `dash proxy reboot` to apply the new configuration.", :yellow
      end

      drifted_hosts.sort.each do |host|
        say "dash-proxy configuration changed, rebooting on #{host}...", :magenta
        run_hook "pre-proxy-reboot", hosts: host
        on(host) do |h|
          Dash::Cli::Proxy::Reboot.new(h, self).run
        end
        run_hook "post-proxy-reboot", hosts: host
      end

      if DASH.config.proxy.load_balancing?
        lb_drifted = Concurrent::Array.new
        lb_stale = Concurrent::Array.new

        on(DASH.config.proxy.effective_loadbalancer) do |host|
          info "Starting loadbalancer on #{host}..."
          execute *DASH.registry.login

          # Bring a pre-rename host across before the container can be created
          # against an empty volume or a network nothing else joined, and make
          # the apps-config directory in the same round trip. Nothing but a
          # `test -f` once it has been.
          execute *DASH.loadbalancer.prepare_boot

          # The load balancer terminates TLS and owns the cache, so its host
          # needs the proxy secrets (acme credentials, cache store) just like
          # the proxy hosts do.
          if (lb_run = DASH.loadbalancer_config.run).secrets?
            execute *DASH.loadbalancer.ensure_proxy_directory
            upload! lb_run.secrets_io, lb_run.secrets_path, mode: "0600"
          else
            execute *DASH.loadbalancer.remove_proxy_secrets_file, raise_on_non_zero_exit: false
          end

          # TLS terminates at the load balancer, so the TLS material the app
          # hosts get - custom certificates and the mTLS client CA - must
          # reach this host too; the LB container reads it through the same
          # apps-config mount the per-host proxies use.
          DASH.config.roles.select(&:running_proxy?).each do |role|
            Dash::Cli::App::SslCertificates.new(host, role, self).run
          end

          # The same drift detection the proxy hosts get: a loadbalancer booted
          # with a different config digest reboots below (or warns, when
          # automatic reboot is off) instead of serving a stale config forever.
          state = Dash::Commands::Proxy::State.parse(
            capture_with_info(*DASH.loadbalancer.inspect_state, raise_on_non_zero_exit: false)
          )

          if state.exists? && state.digest.to_s != DASH.loadbalancer_config.run_config_digest
            if auto_reboot
              # Leave the old loadbalancer serving until its reboot below.
              lb_drifted << host.to_s
            else
              lb_stale << host.to_s
              execute *DASH.loadbalancer.start_or_run
            end
          else
            Dash::Cli::Proxy::LoadbalancerClaim.new(host, self).claim_run_config
            execute *DASH.loadbalancer.start_or_run
          end
        end

        if lb_stale.any?
          say "The loadbalancer on #{lb_stale.sort.join(", ")} is running with a configuration that no longer matches the deploy config. " \
              "Automatic reboot is disabled (proxy: reboot_on_deploy: false) - run `dash proxy reboot` to apply the new configuration.", :yellow
        end

        lb_drifted.sort.each do |host|
          say "Loadbalancer configuration changed, rebooting on #{host}...", :magenta
          run_hook "pre-loadbalancer-reboot", hosts: host
          on(host) do |h|
            Dash::Cli::Proxy::LoadbalancerReboot.new(h, self).run
          end
          run_hook "post-loadbalancer-reboot", hosts: host
        end
      end
    end
  end

  desc "boot_config <set|get|reset>", "Manage dash-proxy boot configuration"
  option :publish, type: :boolean, default: true, desc: "Publish the proxy ports on the host"
  option :publish_host_ip, type: :string, repeatable: true, default: nil, desc: "Host IP address to bind HTTP/HTTPS traffic to. Defaults to all interfaces"
  option :http_port, type: :numeric, default: Dash::Configuration::Proxy::Run::DEFAULT_HTTP_PORT, desc: "HTTP port to publish on the host"
  option :https_port, type: :numeric, default: Dash::Configuration::Proxy::Run::DEFAULT_HTTPS_PORT, desc: "HTTPS port to publish on the host"
  option :log_max_size, type: :string, default: Dash::Configuration::Proxy::Run::DEFAULT_LOG_MAX_SIZE, desc: "Max size of proxy logs"
  option :registry, type: :string, default: nil, desc: "Registry to use for the proxy image"
  option :repository, type: :string, default: nil, desc: "Repository for the proxy image"
  option :image_version, type: :string, default: nil, desc: "Version of the proxy to run"
  option :metrics_port, type: :numeric, default: nil, desc: "Port to report prometheus metrics on"
  option :debug, type: :boolean, default: false, desc: "Whether to run the proxy in debug mode"
  option :docker_options, type: :array, default: [], desc: "Docker options to pass to the proxy container", banner: "option=value option2=value2"
  def boot_config(subcommand)
    say "The proxy boot_config command is deprecated - set the config in the deploy YAML at proxy/run instead", :yellow
    proxy_boot_config = DASH.config.proxy_boot

    case subcommand
    when "set"
      boot_options = [
        *(proxy_boot_config.publish_args(options[:http_port], options[:https_port], options[:publish_host_ip]) if options[:publish]),
        *(proxy_boot_config.logging_args(options[:log_max_size])),
        *("--expose=#{options[:metrics_port]}" if options[:metrics_port]),
        *options[:docker_options].map { |option| "--#{option}" }
      ]

      image = [
        options[:registry].presence,
        options[:repository].presence || proxy_boot_config.repository_name,
        proxy_boot_config.image_name
      ].compact.join("/")

      image_version = options[:image_version]

      run_command_options = { debug: options[:debug] || nil, "metrics-port": options[:metrics_port] }.compact
      run_command = "dash-proxy run #{Dash::Utils.optionize(run_command_options).join(" ")}" if run_command_options.any?

      on(DASH.proxy_hosts) do |host|
        proxy = DASH.proxy(host)
        execute(*proxy.ensure_proxy_directory)
        if boot_options != proxy_boot_config.default_boot_options
          upload! StringIO.new(boot_options.join(" ")), proxy_boot_config.options_file
        else
          execute *proxy.reset_boot_options, raise_on_non_zero_exit: false
        end

        if image != proxy_boot_config.image_default
          upload! StringIO.new(image), proxy_boot_config.image_file
        else
          execute *proxy.reset_image, raise_on_non_zero_exit: false
        end

        if image_version
          upload! StringIO.new(image_version), proxy_boot_config.image_version_file
        else
          execute *proxy.reset_image_version, raise_on_non_zero_exit: false
        end

        if run_command
          upload! StringIO.new(run_command), proxy_boot_config.run_command_file
        else
          execute *proxy.reset_run_command, raise_on_non_zero_exit: false
        end
      end
    when "get"

      on(DASH.proxy_hosts) do |host|
        puts "Host #{host}: #{capture_with_info(*DASH.proxy(host).boot_config)}"
      end
    when "reset"
      on(DASH.proxy_hosts) do |host|
        proxy = DASH.proxy(host)
        execute *proxy.reset_boot_options, raise_on_non_zero_exit: false
        execute *proxy.reset_image, raise_on_non_zero_exit: false
        execute *proxy.reset_image_version, raise_on_non_zero_exit: false
        execute *proxy.reset_run_command, raise_on_non_zero_exit: false
      end
    else
      raise ArgumentError, "Unknown boot_config subcommand #{subcommand}"
    end
  end

  desc "reboot", "Reboot proxy on servers (stop container, remove container, start new container)"
  option :rolling, type: :boolean, default: false, desc: "Reboot proxy on hosts in sequence, rather than in parallel"
  option :confirmed, aliases: "-y", type: :boolean, default: false, desc: "Proceed without confirmation question"
  def reboot
    confirming "This will cause a brief outage on each host. Are you sure?" do
      modify(lock: true, server_lock: true) do
        # Skip proxy on loadbalancer host - it will be handled by loadbalancer reboot
        proxy_hosts = DASH.proxy_hosts
        if DASH.config.proxy.loadbalancer_on_proxy_host?
          proxy_hosts = proxy_hosts - [ DASH.config.proxy.effective_loadbalancer ]
        end

        host_groups = options[:rolling] ? proxy_hosts : [ proxy_hosts ]
        host_groups.each do |hosts|
          next if Array(hosts).empty?

          host_list = Array(hosts).join(",")
          run_hook "pre-proxy-reboot", hosts: host_list
          on(hosts) do |host|
            info "Rebooting dash-proxy on #{host}..."
            Dash::Cli::Proxy::Reboot.new(host, self).run
          end
          run_hook "post-proxy-reboot", hosts: host_list
        end

        if DASH.config.proxy.load_balancing?
          lb_host = DASH.config.proxy.effective_loadbalancer
          run_hook "pre-loadbalancer-reboot", hosts: lb_host

          on(lb_host) do |host|
            Dash::Cli::Proxy::LoadbalancerReboot.new(host, self).run
          end

          run_hook "post-loadbalancer-reboot", hosts: lb_host
        end
      end
    end
  end

  desc "upgrade", "Upgrade to dash-proxy on servers (stop container, remove container, start new container, reboot app)", hide: true
  option :rolling, type: :boolean, default: false, desc: "Reboot proxy on hosts in sequence, rather than in parallel"
  option :confirmed, aliases: "-y", type: :boolean, default: false, desc: "Proceed without confirmation question"
  def upgrade
    invoke_options = { "version" => DASH.config.latest_tag }.merge(options)

    confirming "This will cause a brief outage on each host. Are you sure?" do
      host_groups = options[:rolling] ? DASH.hosts : [ DASH.hosts ]
      host_groups.each do |hosts|
        host_list = Array(hosts).join(",")
        say "Upgrading proxy on #{host_list}...", :magenta
        run_hook "pre-proxy-reboot", hosts: host_list
        on(hosts) do |host|
          proxy = DASH.proxy(host)
          execute *DASH.auditor.record("Rebooted proxy"), verbosity: :debug
          execute *DASH.registry.login

          info "Stopping and removing Traefik on #{host}, if running..."
          execute *proxy.cleanup_traefik

          info "Stopping and removing dash-proxy on #{host}, if running..."
          execute *proxy.stop, raise_on_non_zero_exit: false
          execute *proxy.remove_container
          execute *proxy.remove_image
        end

        DASH.with_specific_hosts(hosts) do
          invoke "dash:cli:proxy:boot", [], invoke_options
          reset_invocation(Dash::Cli::Proxy)
          invoke "dash:cli:app:boot", [], invoke_options
          reset_invocation(Dash::Cli::App)
          invoke "dash:cli:prune:all", [], invoke_options
          reset_invocation(Dash::Cli::Prune)
        end

        run_hook "post-proxy-reboot", hosts: host_list
        say "Upgraded proxy on #{host_list}", :magenta
      end
    end
  end

  desc "start", "Start existing proxy container on servers"
  def start
    modify(lock: true, server_lock: true) do
      on(DASH.proxy_hosts) do |host|
        execute *DASH.auditor.record("Started proxy"), verbosity: :debug
        execute *DASH.proxy(host).start
      end

      if DASH.config.proxy.load_balancing?
        on(DASH.config.proxy.effective_loadbalancer) do
          execute *DASH.auditor.record("Started loadbalancer"), verbosity: :debug
          execute *DASH.loadbalancer.start, raise_on_non_zero_exit: false
        end
      end
    end
  end

  desc "stop", "Stop existing proxy container on servers"
  def stop
    modify(lock: true, server_lock: true) do
      on(DASH.proxy_hosts) do |host|
        execute *DASH.auditor.record("Stopped proxy"), verbosity: :debug
        execute *DASH.proxy(host).stop, raise_on_non_zero_exit: false
      end

      # `docker container prune` only collects stopped containers, so leaving the
      # loadbalancer running would also leave `dash proxy remove` unable to
      # remove it.
      if DASH.config.proxy.load_balancing?
        on(DASH.config.proxy.effective_loadbalancer) do
          execute *DASH.auditor.record("Stopped loadbalancer"), verbosity: :debug
          execute *DASH.loadbalancer.stop, raise_on_non_zero_exit: false
        end
      end
    end
  end

  desc "restart", "Restart existing proxy container on servers"
  def restart
    modify(lock: true, server_lock: true) do
      stop
      start
    end
  end

  desc "details", "Show details about proxy container from servers"
  def details
    quiet = options[:quiet]
    on(DASH.proxy_hosts) { |host| puts_by_host host, capture_with_info(*DASH.proxy(host).info), type: "Proxy", quiet: quiet }

    if DASH.config.proxy.load_balancing?
      on(DASH.config.proxy.effective_loadbalancer) do |host|
        puts_by_host host, capture_with_info(*DASH.loadbalancer.info), type: "Loadbalancer"
      end
    end
  end

  desc "logs", "Show log lines from proxy on servers"
  option :since, aliases: "-s", desc: "Show logs since timestamp (e.g. 2013-01-02T13:23:37Z) or relative (e.g. 42m for 42 minutes)"
  option :lines, type: :numeric, aliases: "-n", desc: "Number of log lines to pull from each server"
  option :grep, aliases: "-g", desc: "Show lines with grep match only (use this to fetch specific requests by id)"
  option :follow, aliases: "-f", desc: "Follow logs on primary server (or specific host set by --hosts)"
  option :skip_timestamps, type: :boolean, aliases: "-T", desc: "Skip appending timestamps to logging output"
  def logs
    grep = options[:grep]
    timestamps = !options[:skip_timestamps]

    if options[:follow]
      run_locally do
        proxy = DASH.proxy(DASH.primary_host)
        info "Following logs on #{DASH.primary_host}..."
        info proxy.follow_logs(host: DASH.primary_host, timestamps: timestamps, grep: grep)
        exec proxy.follow_logs(host: DASH.primary_host, timestamps: timestamps, grep: grep)
      end
    else
      since = options[:since]
      lines = options[:lines].presence || ((since || grep) ? nil : 100) # Default to 100 lines if since or grep isn't set

      on(DASH.proxy_hosts) do |host|
        puts_by_host host, capture(*DASH.proxy(host).logs(timestamps: timestamps, since: since, lines: lines, grep: grep)), type: "Proxy"
      end
    end
  end

  desc "remove", "Remove proxy container and image from servers"
  option :force, type: :boolean, default: false, desc: "Force removing proxy when apps are still installed"
  def remove
    modify(lock: true, server_lock: true) do
      if removal_allowed?(options[:force])
        stop
        remove_container
        remove_image
        remove_proxy_directory
      end
    end
  end

  desc "loadbalancer STATUS", "Manage the load balancer"
  def loadbalancer(status)
    case status
    when "info"
      if DASH.config.proxy.load_balancing?
        on(DASH.config.proxy.effective_loadbalancer) do |host|
          puts "Loadbalancer status on #{host}:"
          puts capture_with_info(*DASH.loadbalancer.info)
        end
      else
        puts "Load balancing is not configured"
      end
    when "start"
      if DASH.config.proxy.load_balancing?
        on(DASH.config.proxy.effective_loadbalancer) do |host|
          execute *DASH.registry.login
          # start_or_run falls through to `docker run` on a host with no
          # container, so this is a volume-creating path too and gets the same
          # bridge boot and reboot do (zoolutions/dash#168). It also makes the
          # apps-config directory the bind mount would otherwise have docker
          # create root-owned.
          execute *DASH.loadbalancer.prepare_boot
          execute *DASH.loadbalancer.start_or_run
        end
      else
        puts "Load balancing is not configured"
      end
    when "stop"
      if DASH.config.proxy.load_balancing?
        on(DASH.config.proxy.effective_loadbalancer) do |host|
          execute *DASH.loadbalancer.stop, raise_on_non_zero_exit: false
        end
      else
        puts "Load balancing is not configured"
      end
    when "logs"
      if DASH.config.proxy.load_balancing?
        on(DASH.config.proxy.effective_loadbalancer) do |host|
          puts_by_host host, capture(*DASH.loadbalancer.logs(timestamps: true)), type: "Loadbalancer"
        end
      else
        puts "Load balancing is not configured"
      end
    when "deploy"
      if DASH.config.proxy.load_balancing?
        targets = DASH.loadbalancer_config.target_hosts

        on(DASH.config.proxy.effective_loadbalancer) do |host|
          Dash::Cli::Proxy::LoadbalancerClaim.new(host, self).claim_service
          info "Deploying to loadbalancer on #{host} with targets: #{targets.join(', ')}"
          execute *DASH.loadbalancer.deploy(targets: targets)
        end
      else
        puts "Load balancing is not configured"
      end
    else
      puts "Unknown loadbalancer subcommand: #{status}. Available: info, start, stop, logs, deploy"
    end
  end

  desc "cache SUBCOMMAND", "Manage the response cache (stats, purge)"
  option :count, type: :boolean, default: false, desc: "stats: measure entries and bytes per service (walks a shared store's keyspace)"
  option :json, type: :boolean, default: false, desc: "stats: print the raw report as JSON"
  option :path_prefix, type: :string, default: nil, desc: "purge: drop only the entries below this path, e.g. /assets"
  def cache(subcommand)
    count, json, path_prefix = options[:count], options[:json], options[:path_prefix]

    case subcommand
    when "stats"
      # The cache lives where its policy applies: at the loadbalancer when
      # load balancing (cache is edge-only in the layering contract),
      # otherwise on each proxy host.
      if DASH.config.proxy.load_balancing?
        on(DASH.config.proxy.effective_loadbalancer) do |host|
          puts_by_host host, capture_with_info(*DASH.loadbalancer.cache_stats(count: count, json: json)), type: "Loadbalancer"
        end
      else
        on(DASH.proxy_hosts) do |host|
          puts_by_host host, capture_with_info(*DASH.proxy(host).cache_stats(count: count, json: json)), type: "Proxy"
        end
      end
    when "purge"
      if DASH.config.proxy.load_balancing?
        # The loadbalancer registers one service under the bare service name.
        on(DASH.config.proxy.effective_loadbalancer) do |host|
          execute *DASH.auditor.record("Purged the response cache"), verbosity: :debug
          puts_by_host host, capture_with_info(*DASH.loadbalancer.cache_purge(DASH.config.service, path_prefix: path_prefix)), type: "Loadbalancer"
        end
      else
        # Each proxied role registered its own service, so purge walks them.
        on(DASH.proxy_hosts) do |host|
          execute *DASH.auditor.record("Purged the response cache"), verbosity: :debug

          DASH.roles_on(host).select(&:running_proxy?).each do |role|
            puts_by_host host, capture_with_info(*DASH.proxy(host).cache_purge(role.container_prefix, path_prefix: path_prefix)), type: "Proxy"
          end
        end
      end
    else
      puts "Unknown cache subcommand: #{subcommand}. Available: stats, purge"
    end
  end

  desc "domains SUBCOMMAND [ARGS]", "Inspect TLS domains and their certificate issuance (refresh, list, stats, retry)"
  long_desc <<~DESC
    Inspect the TLS domains this proxy serves, and the state of their certificates.

    `list` shows every domain — both those learned from a domain source and the
    hosts named in deploy.yml — with whether it holds a certificate and, if
    issuance is held, when the hold lifts and why.

    A hold normally clears itself: the proxy re-checks held domains and issues as
    soon as the domain points at it, so a DNS cutover needs no intervention.
    `retry HOST` (or `retry --all`) is for when you already know the cause is
    fixed and would rather not wait.
  DESC
  def domains(subcommand, *args)
    case subcommand
    when "refresh", "list", "stats", "retry"
      # TLS terminates at the load balancer when load balancing, so the
      # dynamic domain set lives there rather than on the per-host proxies.
      if DASH.config.proxy.load_balancing?
        on(DASH.config.proxy.effective_loadbalancer) do |host|
          puts_by_host host, capture_with_info(*DASH.loadbalancer.domains(subcommand, *args)), type: "Loadbalancer"
        end
      else
        on(DASH.proxy_hosts) do |host|
          puts_by_host host, capture_with_info(*DASH.proxy(host).domains(subcommand, *args)), type: "Proxy"
        end
      end
    else
      puts "Unknown domains subcommand: #{subcommand}. Available: refresh, list, stats, retry"
    end
  end

  desc "export_certs LOCAL_PATH", "Export the TLS certificate store to a local archive (contains private keys)"
  def export_certs(local_path)
    load_balancing = DASH.config.proxy.load_balancing?

    # Under the deploy lock: a concurrent deploy could boot or reboot the
    # proxy mid-export, and the offline read below would archive a torn store.
    modify(lock: true, server_lock: true) do
      on(cert_store_host) do |host|
        execute *DASH.auditor.record("Exported the proxy certificate store"), verbosity: :debug

        commands = load_balancing ? DASH.loadbalancer : DASH.proxy(host)
        execute *commands.ensure_apps_config_directory

        # Running: export through the container's RPC socket, under the proxy's
        # certificate write lock. Stopped: read the data directory offline with a
        # one-off container - which may first need the image.
        if capture_with_info(*commands.container_id(only_running: true), raise_on_non_zero_exit: false).strip.present?
          puts capture_with_info(*commands.export_certs)
        else
          execute *DASH.registry.login
          puts capture_with_info(*commands.export_certs_offline)
        end

        # The archive holds private keys; it must not outlive a failed download.
        begin
          download! commands.certs_archive_host_path, local_path
        ensure
          execute *commands.remove_certs_archive, raise_on_non_zero_exit: false
        end
      end
    end
  end

  desc "import_certs", "Import certificates into the TLS certificate store from a Traefik acme.json or an exported archive"
  option :traefik_acme, type: :string, default: nil, desc: "Local path of a Traefik acme.json to import from"
  option :archive, type: :string, default: nil, desc: "Local path of an archive written by dash proxy export_certs"
  option :resolver, type: :string, default: nil, desc: "Import only this Traefik resolver's certificates (default: all, last writer wins per domain)"
  option :force, type: :boolean, default: false, desc: "Overwrite a non-empty certificate store when restoring an archive"
  option :verify, type: :boolean, default: false, desc: "Only verify the archive: report domains and expiries without touching the store"
  def import_certs
    validate_import_certs_options!
    source = options[:traefik_acme] || options[:archive]
    traefik_acme, resolver = options[:traefik_acme].present?, options[:resolver]
    force, verify = options[:force], options[:verify]
    load_balancing = DASH.config.proxy.load_balancing?

    modify(lock: true, server_lock: true) do
      on(cert_store_host) do |host|
        commands = load_balancing ? DASH.loadbalancer : DASH.proxy(host)

        # dash-proxy import runs offline against the data directory - importing
        # under a live proxy risks a torn store. --verify only reads the archive.
        unless verify
          if capture_with_info(*commands.container_id(only_running: true), raise_on_non_zero_exit: false).strip.present?
            raise "Cannot import certificates while the #{load_balancing ? "loadbalancer" : "proxy"} " \
              "is running on #{host} - stop it first " \
              "(dash proxy #{load_balancing ? "loadbalancer stop" : "stop"}), import, then start it again"
          end
        end

        execute *DASH.auditor.record("Imported certificates into the proxy certificate store"), verbosity: :debug
        execute *DASH.registry.login
        execute *commands.ensure_proxy_directory

        # upload! inside the ensure's reach: a failed or partial upload must
        # not leave certificate material behind on the host either.
        begin
          upload! source, commands.certs_import_host_path, mode: "0600"
          puts capture_with_info(*commands.import_certs(
            traefik_acme: traefik_acme, resolver: resolver, force: force, verify: verify))
        ensure
          execute *commands.remove_certs_import, raise_on_non_zero_exit: false
        end
      end
    end
  end

  desc "remove_container", "Remove proxy container from servers", hide: true
  def remove_container
    modify(lock: true, server_lock: true) do
      on(DASH.proxy_hosts) do
        execute *DASH.auditor.record("Removed proxy container"), verbosity: :debug
        execute *DASH.proxy(host).remove_container
      end

      if DASH.config.proxy.load_balancing?
        on(DASH.config.proxy.effective_loadbalancer) do
          execute *DASH.auditor.record("Removed loadbalancer container"), verbosity: :debug
          execute *DASH.loadbalancer.remove_container
        end
      end
    end
  end

  desc "remove_image", "Remove proxy image from servers", hide: true
  def remove_image
    modify(lock: true, server_lock: true) do
      on(DASH.proxy_hosts) do
        execute *DASH.auditor.record("Removed proxy image"), verbosity: :debug
        execute *DASH.proxy(host).remove_image
      end

      if DASH.config.proxy.load_balancing?
        on(DASH.config.proxy.effective_loadbalancer) do
          execute *DASH.auditor.record("Removed loadbalancer image"), verbosity: :debug
          execute *DASH.loadbalancer.remove_image
        end
      end
    end
  end

  desc "remove_proxy_directory", "Remove the proxy directory from servers", hide: true
  def remove_proxy_directory
    modify(lock: true, server_lock: true) do
      on(DASH.proxy_hosts) do
        execute *DASH.proxy(host).remove_proxy_directory, raise_on_non_zero_exit: false
      end

      # Otherwise the ownership registry outlives the load balancer and a later
      # boot would fail against an owner that no longer exists.
      if DASH.config.proxy.load_balancing?
        on(DASH.config.proxy.effective_loadbalancer) do
          execute *DASH.loadbalancer.remove_directory, raise_on_non_zero_exit: false
        end
      end
    end
  end

  private
    # Every host that runs a container on the proxy network. A dedicated
    # loadbalancer host is not in DASH.hosts, and nothing else creates the
    # network there (zoolutions/dash#140).
    def network_hosts
      hosts = DASH.hosts
      hosts |= [ DASH.config.proxy.effective_loadbalancer ] if DASH.config.proxy.load_balancing?
      hosts
    end

    # The host that owns TLS, and so the certificate store: the loadbalancer
    # host when load balancing (TLS terminates at the edge), else the primary
    # host - the same host `loadbalancer: true` would resolve to.
    def cert_store_host
      DASH.config.proxy.load_balancing? ? DASH.config.proxy.effective_loadbalancer : DASH.primary_host
    end

    # Mirrors dash-proxy's own flag groups (import.go), so a contradictory
    # invocation fails before anything is uploaded.
    def validate_import_certs_options!
      if options[:traefik_acme].present? == options[:archive].present?
        raise ArgumentError, "Specify exactly one of --traefik-acme or --archive"
      end

      if options[:resolver].present? && options[:archive].present?
        raise ArgumentError, "--resolver only applies to a Traefik import"
      end

      if options[:traefik_acme].present? && (options[:force] || options[:verify])
        raise ArgumentError, "--force and --verify only apply to an archive"
      end

      if options[:force] && options[:verify]
        raise ArgumentError, "--verify does not touch the store, so it cannot be combined with --force"
      end
    end

    # A shared load balancer tier is the exact case this guard exists for, so it
    # has to cover the load balancer host too - `remove_container` and
    # `remove_image` both act on it.
    def removal_hosts
      hosts = DASH.proxy_hosts.to_a
      hosts |= [ DASH.config.proxy.effective_loadbalancer ] if DASH.config.proxy.load_balancing?
      hosts
    end

    def removal_allowed?(force)
      on(removal_hosts) do |host|
        app_count = capture_with_info(*DASH.server.app_directory_count).chomp.to_i
        raise "The are other applications installed on #{host}" if app_count > 0
      end

      true
    rescue SSHKit::Runner::ExecuteError => e
      raise unless e.message.include?("The are other applications installed on")

      if force
        say "Forcing, so removing the proxy, even though other apps are installed", :magenta
      else
        say "Not removing the proxy, as other apps are installed, ignore this check with dash proxy remove --force", :magenta
      end

      force
    end
end
