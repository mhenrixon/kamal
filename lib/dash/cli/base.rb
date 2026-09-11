require "thor"
require "time"
require "dash/sshkit_with_ext"

module Dash::Cli
  class Base < Thor
    include SSHKit::DSL

    VERBOSITY = { verbose: :debug, quiet: :error }.freeze
    AUTOMATIC_DEPLOY_LOCK_MESSAGE = "Automatic deploy lock"

    class LockHeldError < StandardError; end
    class LockMissingError < StandardError; end

    # Hooks set process-global state (the hook env and the SSHKit verbosity), so
    # serialize them: some fire from inside SSHKit's per-host threads.
    HOOK_MUTEX = Mutex.new

    def self.exit_on_failure?() true end
    def self.dynamic_command_class() Dash::Cli::Alias::Command end

    # One legacy-project-directory deprecation notice per process. Tests reset it
    # in CliTestCase, the same way they reset the DASH singleton.
    class << self
      attr_accessor :legacy_project_directory_warned
    end

    class_option :verbose, type: :boolean, aliases: "-v", desc: "Detailed logging"
    class_option :quiet, type: :boolean, aliases: "-q", desc: "Minimal logging"

    class_option :version, desc: "Run commands against a specific app version"

    class_option :primary, type: :boolean, aliases: "-p", desc: "Run commands only on primary host instead of all"
    class_option :hosts, aliases: "-h", desc: "Run commands on these hosts instead of all (separate by comma, supports wildcards with *)"
    class_option :roles, aliases: "-r", desc: "Run commands on these roles instead of all (separate by comma, supports wildcards with *)"

    class_option :config_file, aliases: "-c", default: "config/deploy.yml", desc: "Path to config file"
    class_option :destination, aliases: "-d", desc: "Specify destination to be used for config file (staging -> deploy.staging.yml)"

    class_option :skip_hooks, aliases: "-H", type: :boolean, default: false, desc: "Don't run hooks"

    class_option :lock_wait, type: :boolean, default: false, desc: "Wait for the deploy lock if it's already held instead of failing immediately"
    class_option :lock_wait_timeout, type: :numeric, default: 900, desc: "Maximum seconds to wait for the deploy lock when --lock-wait is set"
    class_option :lock_wait_interval, type: :numeric, default: 15, desc: "Seconds between deploy lock polls when --lock-wait is set"

    def initialize(args = [], local_options = {}, config = {})
      if config[:current_command].is_a?(Dash::Cli::Alias::Command)
        # When Thor generates a dynamic command, it doesn't attempt to parse the arguments.
        # For our purposes, it means the arguments are passed in args rather than local_options.
        super([], args, config)
      else
        super
      end

      unless DASH.configured?
        initialize_commander
        warn_on_legacy_project_directory(config[:current_command]&.name)
      end
    end

    # Public so collaborators like Dash::Cli::App::Boot can fire hooks, but not a Thor command.
    no_commands do
      def run_hook(hook, **extra_details)
        if !options[:skip_hooks] && DASH.hook.hook_exists?(hook)
          details = {
            hosts: DASH.hosts.join(","),
            roles: DASH.specific_roles&.join(","),
            lock: DASH.holding_lock?.to_s,
            command: command,
            subcommand: subcommand
          }.compact

          hooks_output = DASH.config.hooks_output_for(hook)

          # CLI flags override config: -q hides all, -v shows all
          # Config setting :verbose forces output, :quiet forces silence
          hook_verbosity = if DASH.verbosity == :info && hooks_output
            VERBOSITY.fetch(hooks_output)
          else
            DASH.verbosity
          end

          HOOK_MUTEX.synchronize do
            with_env DASH.hook.env(**details, **extra_details) do
              DASH.with_verbosity(hook_verbosity) do
                run_locally do
                  execute *DASH.hook.run(hook)
                end
              end
            rescue SSHKit::Command::Failed => e
              raise HookError.new("Hook `#{hook}` failed:\n#{e.message}")
            end
          end
        end
      end
    end

    private
      def options_with_subcommand_class_options
        options.merge(@_initializer.last[:class_options] || {})
      end

      # Process-scoped rather than commander-scoped: Dash::Cli::Alias::Command
      # resets DASH and re-enters Dash::Cli::Main.start, so an aliased command
      # builds a second commander and would otherwise warn twice. `dash migrate`
      # is exempt - telling an operator to run the command they are running is noise.
      def warn_on_legacy_project_directory(command_name)
        return if command_name == "migrate"
        return if Dash::Cli::Base.legacy_project_directory_warned
        return unless Dash::ProjectDirectory.legacy?

        Dash::Cli::Base.legacy_project_directory_warned = true

        say "Using the legacy #{Dash::ProjectDirectory::LEGACY}/ project directory. Run `dash migrate` to move it to " \
            "#{Dash::ProjectDirectory::CURRENT}/ (#{Dash::ProjectDirectory::LEGACY}/ support is removed in dash 5.0).", :yellow
      end

      def initialize_commander
        DASH.tap do |commander|
          if options[:verbose]
            ENV["VERBOSE"] = "1" # For backtraces via cli/start
            commander.verbosity = VERBOSITY[:verbose]
          end

          if options[:quiet]
            commander.verbosity = VERBOSITY[:quiet]
          end

          commander.configure \
            config_file: Pathname.new(File.expand_path(options[:config_file])),
            destination: options[:destination],
            version: options[:version]

          commander.specific_hosts    = options[:hosts]&.split(",")
          commander.specific_roles    = options[:roles]&.split(",")
          commander.specific_primary! if options[:primary]

          commander.lock_wait          = options[:lock_wait]
          commander.lock_wait_timeout  = options[:lock_wait_timeout]
          commander.lock_wait_interval = options[:lock_wait_interval]
        end
      end

      # `setup` wraps `deploy`, so this nests. Each level reports its own total; the phase
      # table belongs to the outermost, which is the one that saw every phase.
      def print_runtime
        started_at = Time.now
        @print_runtime_depth = @print_runtime_depth.to_i + 1
        record_startup_timing if @print_runtime_depth == 1
        yield
        Time.now - started_at
      rescue StandardError => e
        # Kept so the saved report says how the run ended. `setup` nests, and the inner
        # deploy sets it first — the outermost writer reads the same error either way.
        @report_error = e
        raise
      ensure
        @print_runtime_depth -= 1
        runtime = Time.now - started_at
        puts "  Finished all in #{sprintf("%.1f seconds", runtime)}"
        finish_report(started_at, runtime) if @print_runtime_depth.zero? && DASH.timings.any?
      end

      # Trends, then the table, then the saved JSON. Each half is guarded on its own so a
      # report that cannot be written still prints, and a table that cannot be compared is
      # still a table — none of this is allowed to be why a deploy ends badly.
      def finish_report(started_at, runtime)
        run = nil

        guarded_report do
          run = report_run(started_at, runtime)
          DASH.report.advice += report_trends(run)
        end

        puts DASH.report.lines

        guarded_report { write_report(run) } if run
      end

      # What this invocation was, for the saved report and for the trend rules that
      # compare it with the invocations before it.
      def report_run(started_at, runtime)
        {
          command: [ command, subcommand ].compact.join(" "),
          service: DASH.config.service, destination: DASH.config.destination, version: DASH.config.version,
          started_at: started_at.getutc.iso8601, runtime: runtime.round(1),
          status: @report_error ? "failed" : "succeeded",
          error: @report_error && { class: @report_error.class.name, message: @report_error.message }
        }.compact
      end

      def report_trends(run)
        return [] unless DASH.config.report.advice?

        history = Dash::Report::History.new(reports_directory, destination: DASH.config.destination)

        Dash::Report::Trends.new(run.merge(phases: DASH.timings.to_h),
          history: history.recent(DASH.config.report.history), ignore: DASH.config.report.ignore).findings
      end

      def write_report(run)
        @report_path = Dash::Report::Writer.new(DASH.report,
          run: run, keep: DASH.config.report.history, directory: reports_directory).write

        puts "  Report written to #{@report_path}" if @report_path
      end

      def reports_directory
        Dash::ProjectDirectory.join("reports")
      end

      # Summary numbers for the post-deploy hook, so a hook can page on a build that
      # doubled or a warning that appeared without re-deriving any of it. Phases that did
      # not run contribute nothing rather than a zero that reads as "instant".
      def report_hook_details
        guarded_report({}) do
          {
            build_runtime: phase_runtime(Dash::Report::Trends::BUILD_PHASE),
            boot_runtime: phase_runtime(Dash::Report::Trends::BOOT_PHASE),
            advice_count: DASH.report.advice.size.to_s,
            advice_warnings: DASH.report.advice.count(&:warn?).to_s,
            report_path: @report_path
          }.compact
        end
      end

      def phase_runtime(name)
        DASH.timings.seconds_for(name)&.round(1)&.to_s
      end

      # Everything that happened before the first phase could be timed: requiring the gem,
      # Zeitwerk, Thor parsing the command line, and building the config. It is the one row
      # an operator cannot influence from deploy.yml, which is exactly why it has to be
      # visible — a five-second startup is dash's problem, not theirs.
      def record_startup_timing
        DASH.timings.record "Startup (load, config)", Process.clock_gettime(Process::CLOCK_MONOTONIC) - Dash::PROCESS_STARTED_AT
      end

      # Advice about the Dockerfile, run once the build report is in so measured rules can
      # name real seconds. Nothing here is allowed to end a deploy: a report is a courtesy
      # printed next to the work, and the work already succeeded or failed on its own.
      def analyze_report
        guarded_report { DASH.report.analyze!(DASH.config) }
      end

      # `fallback` is what the caller gets when the report could not be produced, for the
      # callers that need a value rather than a side effect.
      def guarded_report(fallback = nil)
        yield
      rescue StandardError => e
        say "Deploy report unavailable: #{e.class}: #{e.message}", :yellow
        say e.backtrace.join("\n"), :yellow if ENV["VERBOSE"]
        fallback
      end

      def timed(name, depth: 0, &block)
        DASH.timings.phase(name, depth: depth, &block)
      end

      # Deploy lock outside, server lock inside. Every caller acquires in that
      # order, and deploy locks are unique per destination, so no cycle forms.
      def modify(lock: false, server_lock: false)
        DASH.modify(command: command, subcommand: subcommand) do
          guarded = -> { server_lock ? with_server_lock { yield } : yield }

          lock ? with_lock(&guarded) : guarded.call
        end
      end

      def say(message = "", *)
        super unless options[:raw]
        DASH.log(message.to_s)
      end

      # Raw output is written straight to stdout for piping, so silence SSHKit's
      # command echoing that would otherwise corrupt the byte stream.
      def with_raw_output(raw, &block)
        raw ? DASH.with_verbosity(:error, &block) : block.call
      end

      # dash-proxy is one container per host, shared by every destination
      # deployed there, but the deploy lock is per-destination — so two
      # destinations deploying at once take different locks and both mutate the
      # same proxy. Anything touching the proxy takes this lock as well.
      def with_server_lock
        if DASH.holding_server_lock?
          yield
        else
          acquire_server_lock

          begin
            yield
          ensure
            release_server_lock
          end
        end
      end

      # Always waits rather than failing: the guarded work is short, and
      # aborting the second destination would defeat running them in parallel.
      #
      # Hosts are taken one at a time and rolled back on contention. Taking them
      # in one `on(hosts)` sweep would leave the locks we did win in place, and
      # every retry would then collide with itself and wait out the timeout.
      def acquire_server_lock
        timed("Acquire server lock") { acquire_server_lock_now }
      end

      def acquire_server_lock_now
        ensure_run_directory

        timeout = DASH.lock_wait_timeout
        interval = DASH.lock_wait_interval
        deadline = Time.now + timeout
        details_shown = false

        say "Acquiring the server lock...", :magenta

        retried_after_release = false

        loop do
          held = []

          begin
            server_lock_hosts.each do |host|
              execute_lock_acquire(AUTOMATIC_DEPLOY_LOCK_MESSAGE, lock: DASH.server_lock, hosts: host)
              held << host
            end

            break
          rescue LockHeldError
            roll_back_server_lock(held)

            unless details_shown
              # The holder can release between our failed mkdir and this read.
              # That means the lock is free, not that anything went wrong, so
              # it must never escape as LockMissingError and fail the deploy.
              status = begin
                capture_lock_status(lock: DASH.server_lock, hosts: server_lock_hosts.first)
              rescue LockMissingError
                nil
              end

              if status
                say "Server lock is held by:", :magenta
                puts status
                details_shown = true
              elsif !retried_after_release
                # Gone already — take one immediate run at it before backing off.
                retried_after_release = true
                next
              end
            end

            remaining = (deadline - Time.now).to_i
            if remaining <= 0
              say "Timed out after #{timeout}s waiting for the server lock", :red
              raise LockError, "Timed out waiting for server lock"
            end

            say "Waiting #{interval}s for the server lock (#{remaining}s remaining)...", :magenta
            sleep [ interval, remaining ].min
          rescue StandardError
            # Anything else - a dropped SSH connection on a host that idled
            # through the wait, a full disk - leaves the hosts we did take
            # locked. holding_server_lock? is still false, so with_server_lock's
            # ensure never runs and nothing else would ever release them.
            roll_back_server_lock(held)
            raise
          end
        end

        DASH.holding_server_lock = true
      end

      # Never raises: on the contention path a raise here would abandon the
      # locks it was rolling back, and on the failure path it would replace the
      # error the operator needs to see.
      def roll_back_server_lock(held)
        release_server_lock_on(held)
      rescue StandardError => e
        say "Error releasing the server lock on #{Array(held).join(", ")}: #{e.message}", :red
      end

      def release_server_lock
        say "Releasing the server lock...", :magenta
        release_server_lock_on(server_lock_hosts)

        DASH.holding_server_lock = false
      end

      # Only ever called with hosts this process actually locked, so a missing
      # directory means someone already cleaned up, not that we may delete
      # another deploy's lock.
      #
      # Every host is attempted even after one fails - stopping at the first
      # error would strand the remaining locks with no one left to release them
      # - and the first error is re-raised once the sweep is done.
      def release_server_lock_on(hosts)
        error = nil

        Array(hosts).each do |host|
          execute_lock_release(lock: DASH.server_lock, hosts: host)
        rescue LockMissingError
          nil
        rescue StandardError => e
          error ||= e
        end

        raise error if error
      end

      def server_lock_hosts
        DASH.proxy_hosts.presence || DASH.hosts
      end

      def with_lock
        if DASH.holding_lock?
          yield
        else
          acquire_lock

          begin
            yield
          rescue
            begin
              release_lock
            rescue => e
              say "Error releasing the deploy lock: #{e.message}", :red
            end
            raise
          end

          release_lock
        end
      end

      def confirming(question)
        return yield if options[:confirmed]

        if ask(question, limited_to: %w[ y N ], default: "N") == "y"
          yield
        else
          say "Aborted", :red
        end
      end

      def acquire_lock
        timed("Acquire deploy lock") { acquire_lock_now }
      end

      def acquire_lock_now
        ensure_run_directory

        if DASH.lock_wait
          acquire_lock_with_wait
        else
          raise_if_locked do
            say "Acquiring the deploy lock...", :magenta
            execute_lock_acquire(AUTOMATIC_DEPLOY_LOCK_MESSAGE)
          end
        end

        DASH.holding_lock = true
      end

      def acquire_lock_with_wait
        timeout = DASH.lock_wait_timeout
        interval = DASH.lock_wait_interval
        deadline = Time.now + timeout
        details_shown = false

        say "Acquiring the deploy lock (waiting up to #{timeout}s)...", :magenta

        loop do
          execute_lock_acquire(AUTOMATIC_DEPLOY_LOCK_MESSAGE)
          break
        rescue LockHeldError
          unless details_shown
            status = capture_lock_status

            say "Deploy lock is held by:", :magenta
            puts status

            unless status.include?(AUTOMATIC_DEPLOY_LOCK_MESSAGE)
              raise LockError, "Deploy lock held manually, not waiting. Run 'dash lock help' for more information"
            end

            details_shown = true
          end

          remaining = (deadline - Time.now).to_i
          if remaining <= 0
            say "Timed out after #{timeout}s waiting for the deploy lock", :red
            raise LockError, "Timed out waiting for deploy lock"
          end

          say "Retrying in #{interval}s (#{remaining}s remaining)...", :magenta
          sleep [ interval, remaining ].min
        end
      end

      def release_lock
        say "Releasing the deploy lock...", :magenta
        execute_lock_release

        DASH.holding_lock = false
      end

      def raise_if_locked
        yield
      rescue LockHeldError
        say "Deploy lock already in place!", :red
        puts capture_lock_status
        raise LockError, "Deploy lock found. Run 'dash lock help' for more information"
      end

      def execute_lock_acquire(message, lock: DASH.lock, hosts: DASH.primary_host)
        on(hosts) { execute *lock.acquire(message, DASH.config.version), verbosity: :debug }
      rescue SSHKit::Runner::ExecuteError => e
        raise LockHeldError if e.message =~ /cannot create directory/
        raise
      end

      def execute_lock_release(lock: DASH.lock, hosts: DASH.primary_host)
        on(hosts) { execute *lock.release, verbosity: :debug }
      rescue SSHKit::Runner::ExecuteError => e
        raise LockMissingError if e.message =~ /No such file or directory/
        raise
      end

      def capture_lock_status(lock: DASH.lock, hosts: DASH.primary_host)
        status = nil
        on(hosts) { status = capture_with_debug(*lock.status) }
        status
      rescue SSHKit::Runner::ExecuteError => e
        raise LockMissingError if e.message =~ /No such file or directory/
        raise
      end

      def on(*args, &block)
        pre_connect_if_required

        super
      end

      def pre_connect_if_required
        if !DASH.connected?
          run_hook "pre-connect", secrets: true unless options[:skip_hooks]
          DASH.connected = true
        end
      end

      def command
        @kamal_command ||= begin
          invocation_class, invocation_commands = *first_invocation
          if invocation_class == Dash::Cli::Main
            invocation_commands[0]
          else
            Dash::Cli::Main.subcommand_classes.find { |command, clazz| clazz == invocation_class }[0]
          end
        end
      end

      def subcommand
        @kamal_subcommand ||= begin
          invocation_class, invocation_commands = *first_invocation
          invocation_commands[0] if invocation_class != Dash::Cli::Main
        end
      end

      def first_invocation
        instance_variable_get("@_invocations").first
      end

      def reset_invocation(cli_class)
        instance_variable_get("@_invocations")[cli_class].pop
      end

      def ensure_run_directory
        on(DASH.hosts) do
          execute(*DASH.server.ensure_run_directory)
        end
      end

      def with_env(env)
        current_env = ENV.to_h.dup
        ENV.update(env)
        yield
      ensure
        ENV.clear
        ENV.update(current_env)
      end

      def ensure_docker_installed
        run_locally do
          begin
            execute *DASH.builder.ensure_docker_installed
          rescue SSHKit::Command::Failed => e
            error = e.message =~ /command not found/ ?
              "Docker is not installed locally" :
              "Docker buildx plugin is not installed locally"

            raise DependencyError, error
          end
        end
      end
  end
end
