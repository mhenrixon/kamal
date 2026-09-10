class Dash::Cli::Build < Dash::Cli::Base
  class BuildError < StandardError; end

  desc "deliver", "Build app and push app image to registry then pull image on servers"
  def deliver
    invoke :push
    invoke :pull
  end

  desc "push", "Build and push app image to registry"
  option :output, type: :string, default: "registry", banner: "export_type", desc: "Exported type for the build result, and may be any exported type supported by 'buildx --output'."
  option :no_cache, type: :boolean, default: false, desc: "Build without using Docker's build cache"
  def push
    cli = self

    # Ensure pre-connect hooks run before the build, they may be needed for a remote builder
    # or the pre-build hooks.
    pre_connect_if_required

    ensure_docker_installed
    setup_local_registry      if DASH.registry.local?
    login_to_registry_locally unless DASH.registry.local?

    run_hook "pre-build"

    uncommitted_changes = Dash::Git.uncommitted_changes

    if DASH.config.builder.git_clone?
      if uncommitted_changes.present?
        say "Building from a local git clone, so ignoring these uncommitted changes:\n #{uncommitted_changes}", :yellow
      end

      run_locally do
        Clone.new(self).prepare
      end
    elsif uncommitted_changes.present?
      say "Building with uncommitted changes:\n #{uncommitted_changes}", :yellow
    end

    parser = build_progress_parser
    handler = handler_for(parser)

    forward_local_registry_port_for_remote_builder do
      with_env(DASH.config.builder.secrets) do
        run_locally do
          begin
            execute *DASH.builder.inspect_builder
          rescue SSHKit::Command::Failed => e
            if e.message =~ /(context not found|no builder|no compatible builder|does not exist)/
              warn "Missing compatible builder, so creating a new one first"
              begin
                cli.remove
              rescue SSHKit::Command::Failed
                raise unless e.message =~ /(context not found|no builder|does not exist)/
              end
              cli.create
            else
              raise
            end
          end

          # Get the command here to ensure the Dir.chdir doesn't interfere with it
          push = DASH.builder.push(cli.options[:output], no_cache: cli.options[:no_cache])

          DASH.with_verbosity(:debug) do
            Dir.chdir(DASH.config.builder.build_directory) { execute *push, env: DASH.builder.push_env, **handler }
          end
        end
      end
    end
  ensure
    record_build_report parser
  end

  desc "pull", "Pull app image from registry onto servers"
  def pull
    login_to_registry_remotely unless DASH.registry.local?

    forward_local_registry_port(DASH.hosts, **DASH.config.ssh.options) do
      if (first_hosts = mirror_hosts).any?
        #  Pull on a single host per mirror first to seed them
        say "Pulling image on #{first_hosts.join(", ")} to seed the #{"mirror".pluralize(first_hosts.count)}...", :magenta
        pull_on_hosts(first_hosts)
        say "Pulling image on remaining hosts...", :magenta
        pull_on_hosts(DASH.app_hosts - first_hosts)
      else
        pull_on_hosts(DASH.app_hosts)
      end
    end
  end

  desc "create", "Create a build setup"
  def create
    if (remote_host = DASH.config.builder.remote)
      connect_to_remote_host(remote_host)
    end

    run_locally do
      begin
        debug "Using builder: #{DASH.builder.name}"
        execute *DASH.builder.create
      rescue SSHKit::Command::Failed => e
        if e.message =~ /stderr=(.*)/
          error "Couldn't create remote builder: #{$1}"
          false
        else
          raise
        end
      end
    end
  end

  desc "remove", "Remove build setup"
  def remove
    run_locally do
      debug "Using builder: #{DASH.builder.name}"
      execute *DASH.builder.remove
    end
  end

  desc "details", "Show build setup"
  def details
    run_locally do
      puts "Builder: #{DASH.builder.name}"
      puts capture(*DASH.builder.info)
    end
  end

  desc "dev", "Build using the working directory, tag it as dirty, and push to local image store."
  option :output, type: :string, default: "docker", banner: "export_type", desc: "Exported type for the build result, and may be any exported type supported by 'buildx --output'."
  option :no_cache, type: :boolean, default: false, desc: "Build without using Docker's build cache"
  def dev
    cli = self

    ensure_docker_installed

    docker_included_files = Set.new(Dash::Docker.included_files)
    git_uncommitted_files = Set.new(Dash::Git.uncommitted_files)
    git_untracked_files = Set.new(Dash::Git.untracked_files)

    docker_uncommitted_files = docker_included_files & git_uncommitted_files
    if docker_uncommitted_files.any?
      say "WARNING: Files with uncommitted changes will be present in the dev container:", :yellow
      docker_uncommitted_files.sort.each { |f| say "  #{f}", :yellow }
      say
    end

    docker_untracked_files = docker_included_files & git_untracked_files
    if docker_untracked_files.any?
      say "WARNING: Untracked files will be present in the dev container:", :yellow
      docker_untracked_files.sort.each { |f| say "  #{f}", :yellow }
      say
    end

    parser = build_progress_parser
    handler = handler_for(parser)

    with_env(DASH.config.builder.secrets) do
      run_locally do
        build = DASH.builder.push(cli.options[:output], tag_as_dirty: true, no_cache: cli.options[:no_cache])
        DASH.with_verbosity(:debug) do
          execute(*build, **handler)
        end
      end
    end
  ensure
    record_build_report parser
  end

  private
    # Buildpacks print a total and nothing else, so there is nothing for the parser to
    # read and no reason to attach it.
    def build_progress_parser
      Dash::Build::ProgressParser.new unless DASH.builder.pack?
    end

    def handler_for(parser)
      parser ? { interaction_handler: parser } : {}
    end

    # Runs whether the build succeeded or failed: a partial report naming the step that
    # broke is exactly what an operator wants from a failed build. Measurement must never
    # be the reason a build fails, so nothing in here is allowed to raise.
    def record_build_report(parser)
      return unless parser

      parser.finish
      DASH.report.build = parser.result

      say "Deploy report unavailable: #{parser.error.class}: #{parser.error.message}", :yellow if parser.error
      print_build_report unless DASH.report.build_entry
    rescue StandardError => e
      say "Deploy report unavailable: #{e.class}: #{e.message}", :yellow
      say e.backtrace.join("\n"), :yellow if ENV["VERBOSE"]
    end

    # A standalone `dash build push` has no phase table to sit under, but a CI pipeline
    # that splits build from deploy should still see where the build time went.
    def print_build_report
      rows = DASH.report.build_lines
      return if rows.empty?

      puts "  Build"
      puts rows
    end

    def connect_to_remote_host(remote_host)
      remote_uri = URI.parse(remote_host)
      if remote_uri.scheme == "ssh"
        host = SSHKit::Host.new(
          hostname: remote_uri.host,
          ssh_options: { user: remote_uri.user, port: remote_uri.port }.compact
        )
        on(host, options) do
          execute "true"
        end
      end
    end

    def mirror_hosts
      if DASH.app_hosts.many?
        mirror_hosts = Concurrent::Hash.new
        on(DASH.app_hosts) do |host|
          first_mirror = capture_with_info(*DASH.builder.first_mirror).strip.presence
          mirror_hosts[first_mirror] ||= host.to_s if first_mirror
        rescue SSHKit::Command::Failed => e
          raise unless e.message =~ /error calling index: reflect: slice index out of range/
        end
        mirror_hosts.values
      else
        []
      end
    end

    def pull_on_hosts(hosts)
      on(hosts) do
        execute *DASH.auditor.record("Pulled image with version #{DASH.config.version}"), verbosity: :debug
        execute *DASH.builder.clean, raise_on_non_zero_exit: false
        execute *DASH.builder.pull
        execute *DASH.builder.validate_image
      end
    end

    def setup_local_registry
      run_locally do
        execute *DASH.registry.setup
      end
    end

    def login_to_registry_locally
      run_locally do
        execute *DASH.registry.login
      end
    end

    def login_to_registry_remotely
      on(DASH.app_hosts) do
        execute *DASH.registry.login
      end
    end

    def forward_local_registry_port_for_remote_builder(&block)
      if DASH.builder.remote?
        remote_uri = URI(DASH.config.builder.remote)
        forward_local_registry_port([ remote_uri.host ], **remote_builder_ssh_options(remote_uri), &block)
      else
        yield
      end
    end

    def forward_local_registry_port(hosts, **ssh_options, &block)
      if DASH.config.registry.local?
        say "Setting up local registry port forwarding to #{hosts.join(', ')}..."
        PortForwarding.new(hosts, DASH.config.registry.local_port, **ssh_options).forward(&block)
      else
        yield
      end
    end

    def remote_builder_ssh_options(remote_uri)
      { user: remote_uri.user,
        port: remote_uri.port,
        keepalive: DASH.config.ssh.options[:keepalive],
        keepalive_interval: DASH.config.ssh.options[:keepalive_interval],
        logger: DASH.config.ssh.options[:logger]
      }.compact
    end
end
