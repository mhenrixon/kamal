class Dash::Commands::Registry < Dash::Commands::Base
  LOCAL_CONTAINER_NAME = "dash-docker-registry"
  LEGACY_LOCAL_CONTAINER_NAME = "kamal-docker-registry"

  def login(registry_config: nil)
    registry_config ||= config.registry

    return if registry_config.local?

    docker :login,
      registry_config.server,
      "-u", sensitive(Dash::Utils.escape_shell_value(registry_config.username)),
      "-p", sensitive(Dash::Utils.escape_shell_value(registry_config.password))
  end

  # The login and whatever has to happen after it on the same host, in one round trip.
  # `docker login` prints "Login Succeeded" to stdout, so its output is redirected away:
  # a caller that captures this gets the folded command's answer and nothing else. A local
  # registry needs no login at all, and the fold collapses to the commands alone.
  #
  # The credentials stay wrapped in sensitive(...) - composing keeps the array elements
  # intact, so SSHKit redacts them here exactly as it does for a standalone login.
  def login_then(*commands, registry_config: nil)
    login = login(registry_config: registry_config)
    login = [ *login, ">", "/dev/null" ] if login

    combine login, *commands
  end

  def logout(registry_config: nil)
    registry_config ||= config.registry

    docker :logout, registry_config.server
  end

  def setup(registry_config: nil)
    registry_config ||= config.registry

    combine \
      docker(:start, LOCAL_CONTAINER_NAME),
      docker(:run, "--detach", "-p", "127.0.0.1:#{registry_config.local_port}:5000", "--name", LOCAL_CONTAINER_NAME, "registry:3"),
      by: "||"
  end

  # The legacy container is torn down alongside the current one so an operator's
  # laptop doesn't keep a stray kamal-docker-registry holding the local port
  # after upgrading. Dash::Cli::Registry#remove already runs this with
  # raise_on_non_zero_exit: false, so a missing container of either name is fine.
  def remove
    chain \
      combine(docker(:stop, LOCAL_CONTAINER_NAME), docker(:rm, LOCAL_CONTAINER_NAME)),
      combine(docker(:stop, LEGACY_LOCAL_CONTAINER_NAME), docker(:rm, LEGACY_LOCAL_CONTAINER_NAME))
  end

  def local?
    config.registry.local?
  end
end
