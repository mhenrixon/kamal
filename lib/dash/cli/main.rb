class Dash::Cli::Main < Dash::Cli::Base
  desc "setup", "Setup all accessories, push the env, and deploy app to servers"
  option :skip_push, aliases: "-P", type: :boolean, default: false, desc: "Skip image build and push"
  option :no_cache, type: :boolean, default: false, desc: "Build without using Docker's build cache"
  def setup
    print_runtime do
      modify(lock: true) do
        invoke_options = deploy_options

        say "Ensure Docker is installed...", :magenta
        timed("Ensure Docker is installed") { invoke "dash:cli:server:bootstrap", [], invoke_options }

        deploy(boot_accessories: true)
      end
    end
  end

  desc "deploy", "Deploy app to servers"
  option :skip_push, aliases: "-P", type: :boolean, default: false, desc: "Skip image build and push"
  option :no_cache, type: :boolean, default: false, desc: "Build without using Docker's build cache"
  def deploy(boot_accessories: false)
    modify do
      runtime = print_runtime do
        invoke_options = deploy_options

        print_config_banner

        say "Validate configuration and secrets...", :magenta
        timed("Validate config and secrets") { DASH.config.validate_secrets!(include_accessories: boot_accessories) }

        if options[:skip_push]
          say "Pull app image...", :magenta
          timed("Pull app image") { invoke "dash:cli:build:pull", [], invoke_options }
        else
          say "Build and push app image...", :magenta
          timed("Build and push app image") do |entry|
            DASH.report.build_entry = entry
            invoke "dash:cli:build:deliver", [], invoke_options
          end
        end

        # Before the boot, so the advice still prints when a boot fails — a slow build is
        # exactly the kind of thing an operator wants to see on a deploy that went wrong.
        analyze_report

        modify(lock: true) do
          run_hook "pre-deploy", secrets: true

          say "Ensure dash-proxy is running...", :magenta
          timed("Ensure dash-proxy") { invoke "dash:cli:proxy:boot", [], invoke_options }

          timed("Boot accessories") { invoke "dash:cli:accessory:boot", [ "all" ], invoke_options } if boot_accessories

          say "Detect stale containers...", :magenta
          timed("Detect stale containers") { invoke "dash:cli:app:stale_containers", [], invoke_options.merge(stop: true) }

          timed("Boot") { invoke "dash:cli:app:boot", [], invoke_options }

          if DASH.config.proxy.load_balancing?
            say "Updating loadbalancer configuration...", :magenta
            timed("Loadbalancer") { invoke "dash:cli:proxy:loadbalancer", [ "deploy" ], invoke_options }
          end

          say "Prune old containers and images...", :magenta
          timed("Prune") { invoke "dash:cli:prune:all", [], invoke_options }
        end
      end

      run_hook "post-deploy", secrets: true, runtime: runtime.round.to_s, **report_hook_details
    end
  end

  desc "redeploy", "Deploy app to servers without bootstrapping servers, starting dash-proxy and pruning"
  option :skip_push, aliases: "-P", type: :boolean, default: false, desc: "Skip image build and push"
  option :no_cache, type: :boolean, default: false, desc: "Build without using Docker's build cache"
  def redeploy
    modify do
      runtime = print_runtime do
        invoke_options = deploy_options

        print_config_banner

        say "Validate configuration and secrets...", :magenta
        timed("Validate config and secrets") { DASH.config.validate_secrets! }

        if options[:skip_push]
          say "Pull app image...", :magenta
          timed("Pull app image") { invoke "dash:cli:build:pull", [], invoke_options }
        else
          say "Build and push app image...", :magenta
          timed("Build and push app image") do |entry|
            DASH.report.build_entry = entry
            invoke "dash:cli:build:deliver", [], invoke_options
          end
        end

        # Before the boot, so the advice still prints when a boot fails — a slow build is
        # exactly the kind of thing an operator wants to see on a deploy that went wrong.
        analyze_report

        modify(lock: true) do
          run_hook "pre-deploy", secrets: true

          say "Detect stale containers...", :magenta
          timed("Detect stale containers") { invoke "dash:cli:app:stale_containers", [], invoke_options.merge(stop: true) }

          timed("Boot") { invoke "dash:cli:app:boot", [], invoke_options }

          if DASH.config.proxy.load_balancing?
            say "Updating loadbalancer configuration...", :magenta
            timed("Loadbalancer") { invoke "dash:cli:proxy:loadbalancer", [ "deploy" ], invoke_options }
          end
        end
      end

      run_hook "post-deploy", secrets: true, runtime: runtime.round.to_s, **report_hook_details
    end
  end

  desc "rollback [VERSION]", "Rollback app to VERSION"
  def rollback(version)
    rolled_back = false

    modify do
      runtime = print_runtime do
        modify(lock: true) do
          invoke_options = deploy_options

          DASH.config.version = version

          if container_available?(version)
            run_hook "pre-deploy", secrets: true

            timed("Boot") { invoke "dash:cli:app:boot", [], invoke_options.merge(version: version) }
            rolled_back = true
          else
            say "The app version '#{version}' is not available as a container (use 'dash app containers' for available versions)", :red
          end
        end
      end

      run_hook "post-deploy", secrets: true, runtime: runtime.round.to_s, **report_hook_details if rolled_back
    end
  end

  desc "details", "Show details about all containers"
  def details
    invoke "dash:cli:proxy:details"
    invoke "dash:cli:app:details"
    invoke "dash:cli:accessory:details", [ "all" ]
  end

  desc "audit", "Show audit log from servers"
  def audit
    quiet = options[:quiet]
    on(DASH.hosts) do |host|
      puts_by_host host, capture_with_info(*DASH.auditor.reveal), quiet: quiet
    end
  end

  desc "config", "Show combined config (including secrets!)"
  def config
    run_locally do
      puts Dash::Utils.redacted(DASH.config.to_h).to_yaml
    end
  end

  desc "docs [SECTION]", "Show dash configuration documentation"
  def docs(section = nil)
    case section
    when NilClass
      puts Dash::Configuration.validation_doc
    else
      puts Dash::Configuration.const_get(section.titlecase.to_sym).validation_doc
    end
  rescue NameError
    puts "No documentation found for #{section}"
  end

  desc "doctor", "Diagnose deploy readiness of servers, registry, proxy, ports, DNS, certificates, and per-role readiness gates"
  def doctor
    say "Running readiness checks...", :magenta
    pre_connect_if_required

    doctor = Dash::Cli::Doctor.new
    doctor.run

    print_doctor_report doctor.results

    if doctor.successful?
      say doctor_summary(doctor), :green
    else
      raise Dash::Cli::DoctorError, doctor_failure_message(doctor)
    end
  end

  desc "init", "Create config stub in config/deploy.yml and secrets stub in .dash"
  option :bundle, type: :boolean, default: false, desc: "Add dash to the Gemfile and create a bin/dash binstub"
  def init
    require "fileutils"

    if (deploy_file = Pathname.new(File.expand_path("config/deploy.yml"))).exist?
      puts "Config file already exists in config/deploy.yml (remove first to create a new one)"
    else
      FileUtils.mkdir_p deploy_file.dirname
      FileUtils.cp_r Pathname.new(File.expand_path("templates/deploy.yml", __dir__)), deploy_file
      puts "Created configuration file in config/deploy.yml"
    end

    # Resolved rather than hardcoded to .dash: a project still on .kamal must
    # keep getting its stubs there, or init would create a second directory that
    # silently wins resolution and orphans the operator's real secrets.
    project_directory = Dash::ProjectDirectory.path

    unless (secrets_file = Pathname.new(File.expand_path("#{project_directory}/secrets"))).exist?
      FileUtils.mkdir_p secrets_file.dirname
      FileUtils.cp_r Pathname.new(File.expand_path("templates/secrets", __dir__)), secrets_file
      puts "Created #{project_directory}/secrets file"
    end

    unless (hooks_dir = Pathname.new(File.expand_path("#{project_directory}/hooks"))).exist?
      hooks_dir.mkpath
      Pathname.new(File.expand_path("templates/sample_hooks", __dir__)).each_child do |sample_hook|
        FileUtils.cp sample_hook, hooks_dir, preserve: true
      end
      puts "Created sample hooks in #{project_directory}/hooks"
    end

    if options[:bundle]
      if (binstub = Pathname.new(File.expand_path("bin/dash"))).exist?
        puts "Binstub already exists in bin/dash (remove first to create a new one)"
      else
        puts "Adding dash to Gemfile and bundle..."
        run_locally do
          execute :bundle, :add, :dash
          execute :bundle, :binstubs, :dash
        end
        puts "Created binstub file in bin/dash"
      end
    end
  end

  desc "remove", "Remove dash-proxy, app, accessories, and registry session from servers"
  option :confirmed, aliases: "-y", type: :boolean, default: false, desc: "Proceed without confirmation question"
  def remove
    confirming "This will remove all containers and images. Are you sure?" do
      modify(lock: true) do
        invoke "dash:cli:app:remove", [], options.without(:confirmed)
        invoke "dash:cli:proxy:remove", [], options.without(:confirmed)
        invoke "dash:cli:accessory:remove", [ "all" ], options
        invoke "dash:cli:registry:remove", [], options.without(:confirmed).merge(skip_local: true)
      end
    end
  end

  desc "migrate", "Move this project's .kamal directory to .dash"
  option :dry_run, type: :boolean, default: false, desc: "Report what would move without touching anything"
  def migrate
    Dash::Cli::Main::Migrate.new(dry_run: options[:dry_run]).run.each { |message, color| say message, color }
  end

  desc "upgrade", "Upgrade from Kamal 1.x to 2.0"
  option :confirmed, aliases: "-y", type: :boolean, default: false, desc: "Proceed without confirmation question"
  option :rolling, type: :boolean, default: false, desc: "Upgrade one host at a time"
  def upgrade
    confirming "This will replace Traefik with dash-proxy and restart all accessories" do
      modify(lock: true) do
        if options[:rolling]
          DASH.hosts.each do |host|
            DASH.with_specific_hosts(host) do
              say "Upgrading #{host}...", :magenta
              if DASH.app_hosts.include?(host)
                invoke "dash:cli:proxy:upgrade", [], options.merge(confirmed: true, rolling: false)
                reset_invocation(Dash::Cli::Proxy)
              end
              if DASH.accessory_hosts.include?(host)
                invoke "dash:cli:accessory:upgrade", [ "all" ], options.merge(confirmed: true, rolling: false)
                reset_invocation(Dash::Cli::Accessory)
              end
              say "Upgraded #{host}", :magenta
            end
          end
        else
          say "Upgrading all hosts...", :magenta
          invoke "dash:cli:proxy:upgrade", [], options.merge(confirmed: true)
          invoke "dash:cli:accessory:upgrade", [ "all" ], options.merge(confirmed: true)
          say "Upgraded all hosts", :magenta
        end
      end
    end
  end

  desc "version", "Show dash version"
  def version
    puts Dash::VERSION
  end

  desc "accessory", "Manage accessories (db/redis/search)"
  subcommand "accessory", Dash::Cli::Accessory

  desc "app", "Manage application"
  subcommand "app", Dash::Cli::App

  desc "build", "Build application image"
  subcommand "build", Dash::Cli::Build

  desc "lock", "Manage the deploy lock"
  subcommand "lock", Dash::Cli::Lock

  desc "proxy", "Manage dash-proxy"
  subcommand "proxy", Dash::Cli::Proxy

  desc "prune", "Prune old application images and containers"
  subcommand "prune", Dash::Cli::Prune

  desc "report", "Read the deploy reports saved under .dash/reports"
  subcommand "report", Dash::Cli::Report

  desc "registry", "Login and -out of the image registry"
  subcommand "registry", Dash::Cli::Registry

  desc "secrets", "Helpers for extracting secrets"
  subcommand "secrets", Dash::Cli::Secrets

  desc "server", "Bootstrap servers with curl and Docker"
  subcommand "server", Dash::Cli::Server

  private
    def container_available?(version)
      begin
        on(DASH.app_hosts) do
          DASH.roles_on(host).each do |role|
            container_id = capture_with_info(*DASH.app(role: role, host: host).container_id_for_version(version))
            raise "Container not found" unless container_id.present?
          end
        end
      rescue SSHKit::Runner::ExecuteError, SSHKit::Runner::MultipleExecuteError => e
        if e.message =~ /Container not found/
          say "Error looking for container version #{version}: #{e.message}"
          return false
        else
          raise
        end
      end

      true
    end

    def deploy_options
      base_options = options.without("skip_push")
      base_options = base_options.except("no_cache") unless base_options["no_cache"]
      { "version" => DASH.config.version }.merge(base_options)
    end

    def print_doctor_report(results)
      results.group_by(&:title).each do |title, rows|
        say title
        rows.each { |row| say "  #{row}", Dash::Cli::Doctor::STATUS_COLORS[row.status] }
      end
    end

    def doctor_summary(doctor)
      if doctor.warnings.any?
        "Looks ready to deploy, with #{doctor.warnings.count} warning(s) to review"
      else
        "Everything looks ready to deploy"
      end
    end

    def doctor_failure_message(doctor)
      failing = doctor.failures.map { |failure| "  #{failure.title} - #{failure}" }.join("\n")
      "Found #{doctor.failures.count} failing check(s):\n#{failing}"
    end

    def print_config_banner
      config = DASH.config

      say "Deploying #{config.service}#{" to #{config.destination}" if config.destination} (version #{config.abbreviated_version})", :magenta
      config.roles.each do |role|
        hosts = "#{role.hosts.count} #{"host".pluralize(role.hosts.count)} (#{role.hosts.join(", ")})"
        say "  #{role.name}: #{hosts} — readiness: #{role.readiness_description}", (:yellow if role.readiness_source == :none)
      end
      say "  proxy: #{config.proxy_hosts.join(", ")}" if config.proxy_hosts.any?
      if config.proxy.load_balancing?
        reason = " (auto-enabled: primary role #{config.primary_role.name} has #{config.primary_role.hosts.count} hosts)" unless config.proxy.loadbalancer.present?
        say "  loadbalancer: #{config.proxy.effective_loadbalancer}#{reason}"
      end
      say "  timeouts: deploy #{config.deploy_timeout}s, drain #{config.drain_timeout}s, readiness delay #{config.readiness_delay}s"
    end
end
