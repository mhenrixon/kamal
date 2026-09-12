module Dash::Cli::Healthcheck::Poller
  extend self

  NO_HEALTHCHECK = Dash::Commands::Base::NO_HEALTHCHECK

  # The wait itself happens on the host now (Dash::Commands::App#wait_for_ready), which
  # returns the moment the status is one this poller accepts and otherwise waits out the
  # deadline it is given. So the block is called once for the wait - and once more only to
  # confirm an unchecked container is still running after its readiness delay. Every
  # decision below is the one the client-side poll made, in the same words; what shrank is
  # the number of round trips it took to reach them.
  def wait_for_healthy(role:, &block)
    attempt = 1
    timeout_at = Time.now + DASH.config.deploy_timeout
    readiness_delay = role.readiness_delay

    begin
      status = block.call(:wait, seconds_left(timeout_at))

      if unchecked?(status)
        ensure_no_healthcheck_drift(role, status)

        if docker_state(status) == "running"
          announce_missing_gate(role, readiness_delay)

          # Wait for the readiness delay and confirm it is still running
          if readiness_delay > 0
            sleep readiness_delay
            status = block.call(:confirm)
            ensure_no_healthcheck_drift(role, status)
          end
        end
      end

      unless acceptable?(status)
        raise Dash::Cli::Healthcheck::Error, "container not ready after #{DASH.config.deploy_timeout} seconds (#{status})"
      end
    rescue Dash::Cli::Healthcheck::Error => e
      time_left = timeout_at - Time.now
      if time_left > 0
        sleep_for = [ attempt, time_left ].min
        elapsed = DASH.config.deploy_timeout - time_left
        info "Container not ready yet, retrying in #{sleep_for.ceil}s (#{elapsed.round}s elapsed, #{time_left.round}s left)"
        sleep sleep_for
        attempt += 1
        retry
      else
        raise
      end
    end

    info "Container is healthy!"
  end

  private
    def unchecked?(status)
      status.to_s.start_with?("#{NO_HEALTHCHECK}:")
    end

    def docker_state(status)
      status.to_s.delete_prefix("#{NO_HEALTHCHECK}:")
    end

    # Shared with the host-side wait, which stops looking on exactly these - see
    # Dash::Commands::Base::READY_STATUSES for why the two have to agree.
    def acceptable?(status)
      Dash::Commands::Base::READY_STATUSES.include?(status)
    end

    def seconds_left(timeout_at)
      [ (timeout_at - Time.now).ceil, 0 ].max
    end

    # The config asked docker to probe this container and docker is not probing it — the flags
    # never reached `docker run`. Accepting it would let the deploy pass without ever checking
    # readiness, which is exactly the failure the healthcheck was added to prevent.
    def ensure_no_healthcheck_drift(role, status)
      return unless %i[ healthcheck docker_options ].include?(role.readiness_source)

      raise Dash::Cli::Healthcheck::DriftError,
        "#{role.name} declares a healthcheck but the container reports none (#{status}) — the flags never reached docker. " \
        "Compare `servers/#{role.name}` in your deploy config against `docker inspect --format '{{json .Config.Healthcheck}}'` " \
        "on the container; the deploy would otherwise be accepted without ever probing it."
    end

    # A role nobody made a readiness decision for still boots — the config-time warning owns that
    # policy — but it must not do so silently, because the delay is the only gate there is.
    def announce_missing_gate(role, readiness_delay)
      if role.readiness_gated?
        info "Container is running, waiting for readiness delay of #{readiness_delay} seconds"
      else
        warn "#{role.name} has no healthcheck — accepting the container as ready after the #{readiness_delay}s readiness delay alone. " \
          "Add a `healthcheck:` block to gate the deploy on readiness, or `healthcheck: false` to accept this explicitly."
      end
    end

    def info(message)
      SSHKit.config.output.info(message)
    end

    def warn(message)
      SSHKit.config.output.warn(message)
    end
end
