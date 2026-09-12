module Dash::Commands
  class Base
    delegate :sensitive, :argumentize, to: Dash::Utils

    # Prefixed onto the docker state when the container declares no healthcheck at all, so
    # "nothing is probing this container" stays distinguishable from "the probe passed" —
    # both used to reach the poller as `running`. The state is kept after the prefix so a
    # healthcheck-less container that died still reports why.
    NO_HEALTHCHECK = "no-healthcheck"

    DOCKER_HEALTH_STATUS_FORMAT = "'{{if .State.Health}}{{.State.Health.Status}}{{else}}#{NO_HEALTHCHECK}:{{.State.Status}}{{end}}'"

    # The statuses a boot accepts as ready. Dash::Cli::Healthcheck::Poller decides what a
    # status means; Dash::Commands::App#wait_for_ready only decides when to stop looking,
    # and it stops on exactly these. The two must agree: a status the host loop returned
    # early for that the poller would not accept fails a boot the old client-side poll
    # would have waited out.
    READY_STATUSES = [ "healthy", "#{NO_HEALTHCHECK}:running" ].freeze

    # What a `healthcheck: exec:` probe reports when it exits non-zero. Produced by the
    # host-side wait, read back by the poller, so it is a wire format, not a message.
    EXEC_PROBE_FAILED = "exec probe exited non-zero"

    # The line #wait_for_ready prints to stderr on every attempt, read back by
    # Dash::Cli::Healthcheck::ProgressReporter. stderr, because a capture returns stdout
    # alone - which keeps the captured value the final status and nothing else.
    READINESS_PROGRESS_PREFIX = "dash-readiness"

    attr_accessor :config

    def initialize(config)
      @config = config
    end

    def run_over_ssh(*command, host:)
      "ssh#{ssh_config_args}#{ssh_proxy_args}#{ssh_keys_args} -t #{config.ssh.user}@#{host} -p #{config.ssh.port} '#{command.join(" ").gsub("'", "'\\\\''")}'"
    end

    def container_id_for(container_name:, only_running: false)
      docker :container, :ls, *("--all" unless only_running), "--filter", "'name=^#{container_name}$'", "--quiet"
    end

    def make_directory_for(remote_file)
      make_directory Pathname.new(remote_file).dirname.to_s
    end

    def make_directory(path)
      [ :mkdir, "-p", path ]
    end

    # Creates the run directory, renaming a pre-3b `.kamal` into place first.
    #
    # Lives on Base because two unlocked paths reach the run directory before
    # Dash::Cli::Base#ensure_run_directory does — the auditor records "Pulled
    # image" during `build:pull`, and every `mkdir -p .dash/...` underneath it
    # creates the parent. If any of them made the directory with a bare mkdir,
    # `.dash` would exist by the time the guard ran and the legacy tree would be
    # stranded. Everything that can be first must run the same command.
    #
    # The migration is safe to repeat on every command:
    #
    # - Idempotent - once `.dash` exists the second guard is false forever.
    # - Atomic - the two are siblings in the SSH user's home, so this is a
    #   rename within one filesystem, never a copy.
    # - Invisible to running containers - a bind mount resolves to an inode,
    #   so the live proxy keeps serving from the renamed directory and only
    #   picks up the new path when it is next recreated.
    #
    # `test` leads deliberately: SSHKit's command map passes `if`/`test`/`time`/
    # `exec` through untouched and prefixes everything else with `/usr/bin/env`.
    # The trailing `|| true` keeps the exit status zero when there is nothing to
    # migrate, since callers execute this with raise_on_non_zero_exit on.
    def ensure_run_directory
      combine migrate_legacy_run_directory, make_directory(config.run_directory)
    end

    def remove_directory(path)
      [ :rm, "-r", path ]
    end

    def remove_file(path)
      [ :rm, path ]
    end

    def read_file(file, default: nil)
      combine [ :cat, file, "2>", "/dev/null" ], [ :echo, "\"#{default}\"" ], by: "||"
    end

    def ensure_docker_installed
      combine \
        ensure_local_docker_installed,
        ensure_local_buildx_installed
    end

    private
      def migrate_legacy_run_directory
        any \
          combine(
            [ :test, "-d", Dash::Configuration::LEGACY_RUN_DIRECTORY ],
            [ :test, "!", "-e", config.run_directory ],
            [ :mv, Dash::Configuration::LEGACY_RUN_DIRECTORY, config.run_directory ]
          ),
          [ :true ]
      end

      def combine(*commands, by: "&&")
        commands
          .compact
          .collect { |command| Array(command) + [ by ] }.flatten # Join commands
          .tap     { |commands| commands.pop } # Remove trailing combiner
      end

      def chain(*commands)
        combine *commands, by: ";"
      end

      def pipe(*commands)
        combine *commands, by: "|"
      end

      def append(*commands)
        combine *commands, by: ">>"
      end

      def write(*commands)
        combine *commands, by: ">"
      end

      def any(*commands)
        combine *commands, by: "||"
      end

      def substitute(*commands)
        "\$\(#{commands.join(" ")}\)"
      end

      def xargs(command)
        [ :xargs, command ].flatten
      end

      def shell(command)
        [ :sh, "-c", "'#{command.flatten.join(" ").gsub("'", "'\\\\''")}'" ]
      end

      # Adopts a pre-rename docker volume: creates `volume` from `legacy` if, and
      # only if, `volume` is absent and `legacy` is present. A host with neither
      # exits 0. The first word must be a program, never `!` — see
      # Dash::Commands::Proxy#copy_legacy_config_volume.
      def copy_legacy_volume(legacy:, volume:, image:)
        any \
          volume_exists(volume),
          negate(volume_exists(legacy)),
          [ "(", *combine(docker(:volume, :create, volume), copy_between_volumes(legacy, volume, image: image)), ")" ]
      end

      def negate(command)
        [ "!", *command ]
      end

      def volume_exists(name)
        docker :volume, :inspect, name, ">", "/dev/null", "2>&1"
      end

      def copy_between_volumes(from, to, image:)
        docker \
          :run, "--rm", "--user", "root", "--entrypoint", "sh",
          "--volume", "#{from}:/from",
          "--volume", "#{to}:/to",
          image,
          "-c", "'cp -a /from/. /to/'"
      end

      def docker(*args)
        args.compact.unshift :docker
      end

      def pack(*args)
        args.compact.unshift :pack
      end

      def git(*args, path: nil)
        [ :git, *([ "-C", path ] if path), *args.compact ]
      end

      def grep(*args)
        args.compact.unshift :grep
      end

      def tags(**details)
        Dash::Tags.from_config(config, **details)
      end

      def ssh_config_args
        case config.ssh.config
        when Array
          config.ssh.config.map { |file| " -F #{file}" }.join
        when String
          " -F #{config.ssh.config}"
        when true
          "" # Use default SSH config
        when false
          " -F /dev/null" # Ignore SSH config
        end
      end

      def ssh_proxy_args
        case config.ssh.proxy
        when Net::SSH::Proxy::Jump
          " -J #{config.ssh.proxy.jump_proxies}"
        when Net::SSH::Proxy::Command
          " -o ProxyCommand='#{config.ssh.proxy.command_line_template}'"
        end
      end

      def ssh_keys_args
        "#{ ssh_keys.join("") if ssh_keys}" + "#{" -o IdentitiesOnly=yes" if config.ssh&.keys_only}"
      end

      def ssh_keys
        config.ssh.keys&.map do |key|
          " -i #{key}"
        end
      end

      def ensure_local_docker_installed
        docker "--version"
      end

      def ensure_local_buildx_installed
        docker :buildx, "version"
      end

      def docker_interactive_args
        STDIN.isatty ? "-it" : "-i"
      end
  end
end
