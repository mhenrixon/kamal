require "test_helper"

class CommandsProxyTest < ActiveSupport::TestCase
  setup do
    @config = {
      service: "app", image: "dhh/app", registry: { "username" => "dhh", "password" => "secret" }, servers: [ "1.1.1.1" ], builder: { "arch" => "amd64" }
    }

    ENV["EXAMPLE_API_KEY"] = "456"
  end

  teardown do
    ENV.delete("EXAMPLE_API_KEY")
  end

  test "run" do
    assert_equal \
      "echo $(cat .dash/proxy/options 2> /dev/null || echo \"--publish 80:80 --publish 443:443 --log-opt max-size=10m\") $(cat .dash/proxy/image 2> /dev/null || echo \"ghcr.io/zoolutions/dash-proxy\"):$(cat .dash/proxy/image_version 2> /dev/null || echo \"#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION}\") $(cat .dash/proxy/run_command 2> /dev/null || echo \"\") | xargs docker run --name dash-proxy --network dash --detach --restart unless-stopped --volume dash-proxy-config:/home/dash-proxy/.config/dash-proxy --volume $PWD/.dash/proxy/apps-config:/home/dash-proxy/.apps-config",
      new_command.run.join(" ")
  end

  test "run without configuration" do
    @config.delete(:proxy)

    assert_equal \
      "echo $(cat .dash/proxy/options 2> /dev/null || echo \"--publish 80:80 --publish 443:443 --log-opt max-size=10m\") $(cat .dash/proxy/image 2> /dev/null || echo \"ghcr.io/zoolutions/dash-proxy\"):$(cat .dash/proxy/image_version 2> /dev/null || echo \"#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION}\") $(cat .dash/proxy/run_command 2> /dev/null || echo \"\") | xargs docker run --name dash-proxy --network dash --detach --restart unless-stopped --volume dash-proxy-config:/home/dash-proxy/.config/dash-proxy --volume $PWD/.dash/proxy/apps-config:/home/dash-proxy/.apps-config",
      new_command.run.join(" ")
  end

  test "proxy start" do
    assert_equal \
      "docker container start dash-proxy",
      new_command.start.join(" ")
  end

  test "proxy stop" do
    assert_equal \
      "docker container stop dash-proxy",
      new_command.stop.join(" ")
  end

  test "proxy info" do
    assert_equal \
      "docker ps --filter 'name=^dash-proxy$'",
      new_command.info.join(" ")
  end

  test "proxy logs" do
    assert_equal \
      "docker logs dash-proxy --timestamps 2>&1",
      new_command.logs.join(" ")
  end

  test "proxy logs since 2h" do
    assert_equal \
      "docker logs dash-proxy --since 2h --timestamps 2>&1",
      new_command.logs(since: "2h").join(" ")
  end

  test "proxy logs last 10 lines" do
    assert_equal \
      "docker logs dash-proxy --tail 10 --timestamps 2>&1",
      new_command.logs(lines: 10).join(" ")
  end

  test "proxy logs without timestamps" do
    assert_equal \
      "docker logs dash-proxy 2>&1",
      new_command.logs(timestamps: false).join(" ")
  end

  test "proxy logs with grep hello!" do
    assert_equal \
      "docker logs dash-proxy --timestamps 2>&1 | grep 'hello!'",
      new_command.logs(grep: "hello!").join(" ")
  end

  # Docker ANDs multiple `--filter label=` values, so covering both the current
  # and the pre-rename title is two chained commands. Without the legacy pass a
  # host that has not been through the stage-3c rename keeps its old container
  # and image after `dash proxy remove`.
  test "proxy remove container prunes both the current and the legacy title" do
    assert_equal \
      "docker container prune --force --filter label=org.opencontainers.image.title=dash-proxy && " \
      "docker container prune --force --filter label=org.opencontainers.image.title=kamal-proxy",
      new_command.remove_container.join(" ")
  end

  test "proxy remove image prunes both the current and the legacy title" do
    assert_equal \
      "docker image prune --all --force --filter label=org.opencontainers.image.title=dash-proxy && " \
      "docker image prune --all --force --filter label=org.opencontainers.image.title=kamal-proxy",
      new_command.remove_image.join(" ")
  end

  test "proxy follow logs" do
    assert_equal \
      "ssh -t root@1.1.1.1 -p 22 'docker logs dash-proxy --timestamps --tail 10 --follow 2>&1'",
      new_command.follow_logs(host: @config[:servers].first)
  end

  test "proxy follow logs with grep hello!" do
    assert_equal \
      "ssh -t root@1.1.1.1 -p 22 'docker logs dash-proxy --timestamps --tail 10 --follow 2>&1 | grep \"hello!\"'",
      new_command.follow_logs(host: @config[:servers].first, grep: "hello!")
  end

  test "version" do
    assert_equal \
      "docker inspect dash-proxy --format '{{.Config.Image}}' | awk -F: '{print $NF}'",
      new_command.version.join(" ")
  end

  test "ensure_proxy_directory" do
    assert_equal \
      "mkdir -p .dash/proxy",
      new_command.ensure_proxy_directory.join(" ")
  end

  test "read_boot_options" do
    assert_equal \
      "cat .dash/proxy/options 2> /dev/null || echo \"--publish 80:80 --publish 443:443 --log-opt max-size=10m\"",
      new_command.read_boot_options.join(" ")
  end

  test "read_image" do
    assert_equal \
      "cat .dash/proxy/image 2> /dev/null || echo \"ghcr.io/zoolutions/dash-proxy\"",
      new_command.read_image.join(" ")
  end

  test "read_image_version" do
    assert_equal \
      "cat .dash/proxy/image_version 2> /dev/null || echo \"#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION}\"",
      new_command.read_image_version.join(" ")
  end

  test "read_run_command" do
    assert_equal \
      "cat .dash/proxy/run_command 2> /dev/null || echo \"\"",
      new_command.read_run_command.join(" ")
  end

  test "reset_boot_options" do
    assert_equal \
      "rm .dash/proxy/options",
      new_command.reset_boot_options.join(" ")
  end

  test "reset_image" do
    assert_equal \
      "rm .dash/proxy/image",
      new_command.reset_image.join(" ")
  end

  test "reset_image_version" do
    assert_equal \
      "rm .dash/proxy/image_version",
      new_command.reset_image_version.join(" ")
  end

  test "ensure_apps_config_directory" do
    assert_equal \
      "mkdir -p .dash/proxy/apps-config",
      new_command.ensure_apps_config_directory.join(" ")
  end

  test "reset_run_command" do
    assert_equal \
      "rm .dash/proxy/run_command",
      new_command.reset_run_command.join(" ")
  end

  test "registry run config" do
    @config[:proxy] = { "run" => { "registry" => "registry:4443" } }
    assert_equal \
      "docker run --name dash-proxy --network dash --detach --restart unless-stopped --volume dash-proxy-config:/home/dash-proxy/.config/dash-proxy --volume $PWD/.dash/proxy/apps-config:/home/dash-proxy/.apps-config --publish 80:80 --publish 443:443 --log-opt max-size=10m registry:4443/ghcr.io/zoolutions/dash-proxy:#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION} dash-proxy run --recheck-targets-on-restore",
      new_command.run.join(" ")
  end

  test "repository run config" do
    @config[:proxy] = { "run" => { "repository" => "custom/repo" } }
    assert_equal \
      "docker run --name dash-proxy --network dash --detach --restart unless-stopped --volume dash-proxy-config:/home/dash-proxy/.config/dash-proxy --volume $PWD/.dash/proxy/apps-config:/home/dash-proxy/.apps-config --publish 80:80 --publish 443:443 --log-opt max-size=10m custom/repo:#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION} dash-proxy run --recheck-targets-on-restore",
      new_command.run.join(" ")
  end

  test "image_version run config" do
    @config[:proxy] = { "run" => { "version" => "v1.2.3" } }
    assert_equal \
      "docker run --name dash-proxy --network dash --detach --restart unless-stopped --volume dash-proxy-config:/home/dash-proxy/.config/dash-proxy --volume $PWD/.dash/proxy/apps-config:/home/dash-proxy/.apps-config --publish 80:80 --publish 443:443 --log-opt max-size=10m ghcr.io/zoolutions/dash-proxy:v1.2.3 dash-proxy run --recheck-targets-on-restore",
      new_command.run.join(" ")
  end

  test "bind_ips run config" do
    @config[:proxy] = { "run" => { "bind_ips" => [ "0.0.0.0", "127.0.0.1" ] } }
    assert_equal \
      "docker run --name dash-proxy --network dash --detach --restart unless-stopped --volume dash-proxy-config:/home/dash-proxy/.config/dash-proxy --volume $PWD/.dash/proxy/apps-config:/home/dash-proxy/.apps-config --publish 0.0.0.0:80:80 --publish 0.0.0.0:443:443 --publish 127.0.0.1:80:80 --publish 127.0.0.1:443:443 --log-opt max-size=10m ghcr.io/zoolutions/dash-proxy:#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION} dash-proxy run --recheck-targets-on-restore",
      new_command.run.join(" ")
  end

  test "log_max_size run config" do
    @config[:proxy] = { "run" => { "log_max_size" => "50m" } }
    assert_equal \
      "docker run --name dash-proxy --network dash --detach --restart unless-stopped --volume dash-proxy-config:/home/dash-proxy/.config/dash-proxy --volume $PWD/.dash/proxy/apps-config:/home/dash-proxy/.apps-config --publish 80:80 --publish 443:443 --log-opt max-size=50m ghcr.io/zoolutions/dash-proxy:#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION} dash-proxy run --recheck-targets-on-restore",
      new_command.run.join(" ")
  end

  test "domains" do
    assert_equal \
      "docker exec dash-proxy dash-proxy domains refresh",
      new_command.domains("refresh").join(" ")
  end

  test "debug run config" do
    @config[:proxy] = { "run" => { "debug" => true } }
    assert_equal \
      "docker run --name dash-proxy --network dash --detach --restart unless-stopped --volume dash-proxy-config:/home/dash-proxy/.config/dash-proxy --volume $PWD/.dash/proxy/apps-config:/home/dash-proxy/.apps-config --publish 80:80 --publish 443:443 --log-opt max-size=10m ghcr.io/zoolutions/dash-proxy:#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION} dash-proxy run --debug --recheck-targets-on-restore",
      new_command.run.join(" ")
  end

  test "metrics_port run config" do
    @config[:proxy] = { "run" => { "metrics_port" => 9090 } }
    assert_equal \
      "docker run --name dash-proxy --network dash --detach --restart unless-stopped --volume dash-proxy-config:/home/dash-proxy/.config/dash-proxy --volume $PWD/.dash/proxy/apps-config:/home/dash-proxy/.apps-config --publish 80:80 --publish 443:443 --log-opt max-size=10m --expose=9090 ghcr.io/zoolutions/dash-proxy:#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION} dash-proxy run --metrics-port \"9090\" --recheck-targets-on-restore",
      new_command.run.join(" ")
  end

  test "don't publish run config" do
    @config[:proxy] = { "run" => { "publish" => false } }
    assert_equal \
      "docker run --name dash-proxy --network dash --detach --restart unless-stopped --volume dash-proxy-config:/home/dash-proxy/.config/dash-proxy --volume $PWD/.dash/proxy/apps-config:/home/dash-proxy/.apps-config --log-opt max-size=10m ghcr.io/zoolutions/dash-proxy:#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION} dash-proxy run --recheck-targets-on-restore",
      new_command.run.join(" ")
  end

  test "run with config digest label" do
    @config[:proxy] = { "run" => { "log_max_size" => "10m" } }
    assert_equal \
      "docker run --name dash-proxy --network dash --detach --restart unless-stopped --volume dash-proxy-config:/home/dash-proxy/.config/dash-proxy --label org.dash.proxy-config-digest=abc123 --volume $PWD/.dash/proxy/apps-config:/home/dash-proxy/.apps-config --publish 80:80 --publish 443:443 --log-opt max-size=10m ghcr.io/zoolutions/dash-proxy:#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION} dash-proxy run --recheck-targets-on-restore",
      new_command.run(digest: "abc123").join(" ")
  end

  test "run with config digest label on legacy boot config path" do
    assert_equal \
      "echo $(cat .dash/proxy/options 2> /dev/null || echo \"--publish 80:80 --publish 443:443 --log-opt max-size=10m\") $(cat .dash/proxy/image 2> /dev/null || echo \"ghcr.io/zoolutions/dash-proxy\"):$(cat .dash/proxy/image_version 2> /dev/null || echo \"#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION}\") $(cat .dash/proxy/run_command 2> /dev/null || echo \"\") | xargs docker run --name dash-proxy --network dash --detach --restart unless-stopped --volume dash-proxy-config:/home/dash-proxy/.config/dash-proxy --label org.dash.proxy-config-digest=abc123 --volume $PWD/.dash/proxy/apps-config:/home/dash-proxy/.apps-config",
      new_command.run(digest: "abc123").join(" ")
  end

  test "start_or_run passes digest through" do
    @config[:proxy] = { "run" => {} }
    assert_match \
      "--label org.dash.proxy-config-digest=abc123",
      new_command.start_or_run(digest: "abc123").join(" ")
  end

  test "stop with timeout" do
    assert_equal \
      "docker container stop --time 40 dash-proxy",
      new_command.stop(timeout: 40).join(" ")
  end

  test "pull" do
    @config[:proxy] = { "run" => { "version" => "v1.2.3" } }
    assert_equal \
      "docker pull ghcr.io/zoolutions/dash-proxy:v1.2.3",
      new_command.pull.join(" ")
  end

  test "pull on legacy boot config path" do
    assert_equal \
      "docker pull $(cat .dash/proxy/image 2> /dev/null || echo \"ghcr.io/zoolutions/dash-proxy\"):$(cat .dash/proxy/image_version 2> /dev/null || echo \"#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION}\")",
      new_command.pull.join(" ")
  end

  test "list" do
    assert_equal \
      "docker exec dash-proxy dash-proxy list",
      new_command.list.join(" ")
  end

  test "list json" do
    assert_equal \
      "docker exec dash-proxy dash-proxy list --json",
      new_command.list(json: true).join(" ")
  end

  test "cache stats" do
    assert_equal \
      "docker exec dash-proxy dash-proxy cache stats",
      new_command.cache_stats.join(" ")
  end

  test "cache stats with count and json" do
    assert_equal \
      "docker exec dash-proxy dash-proxy cache stats --count --json",
      new_command.cache_stats(count: true, json: true).join(" ")
  end

  test "cache purge" do
    assert_equal \
      "docker exec dash-proxy dash-proxy cache purge app-web",
      new_command.cache_purge("app-web").join(" ")
  end

  test "cache purge with path prefix" do
    assert_equal \
      "docker exec dash-proxy dash-proxy cache purge app-web --path-prefix \"/assets\"",
      new_command.cache_purge("app-web", path_prefix: "/assets").join(" ")
  end

  test "mount_destinations" do
    assert_equal \
      "docker inspect dash-proxy --format '{{range .Mounts}}{{println .Destination}}{{end}}'",
      new_command.mount_destinations.join(" ")
  end

  test "config_digest reads the new label and falls back to the legacy one" do
    assert_equal \
      "docker inspect dash-proxy --format '{{ with index .Config.Labels \"org.dash.proxy-config-digest\" }}{{ . }}{{ else }}{{ index .Config.Labels \"org.kamal.proxy-config-digest\" }}{{ end }}'",
      new_command.config_digest.join(" ")
  end

  test "container_id" do
    assert_equal \
      "docker container ls --all --filter 'name=^dash-proxy$' --quiet",
      new_command.container_id.join(" ")
  end

  test "run with port_holder joins the holder namespace without publishing" do
    @config[:proxy] = { "run" => { "port_holder" => true } }
    assert_equal \
      "docker run --name dash-proxy --network container:dash-proxy-net --detach --restart unless-stopped --volume dash-proxy-config:/home/dash-proxy/.config/dash-proxy --volume $PWD/.dash/proxy/apps-config:/home/dash-proxy/.apps-config --log-opt max-size=10m ghcr.io/zoolutions/dash-proxy:#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION} dash-proxy run --recheck-targets-on-restore --reuse-port",
      new_command.run.join(" ")
  end

  test "run with a custom container name" do
    @config[:proxy] = { "run" => { "port_holder" => true } }
    assert_match \
      "docker run --name dash-proxy-next --network container:dash-proxy-net",
      new_command.run(name: "dash-proxy-next").join(" ")
  end

  test "run_holder" do
    @config[:proxy] = { "run" => { "port_holder" => true } }
    assert_equal \
      "docker run --name dash-proxy-net --network dash --detach --restart unless-stopped --publish 80:80 --publish 443:443 --log-opt max-size=10m ghcr.io/zoolutions/dash-proxy:#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION} dash-proxy hold",
      new_command.run_holder.join(" ")
  end

  test "start_holder_or_run" do
    @config[:proxy] = { "run" => { "port_holder" => true } }
    assert_match \
      "docker container start dash-proxy-net || docker run --name dash-proxy-net",
      new_command.start_holder_or_run.join(" ")
  end

  test "holder_container_id" do
    @config[:proxy] = { "run" => { "port_holder" => true } }
    assert_equal \
      "docker container ls --filter 'name=^dash-proxy-net$' --quiet",
      new_command.holder_container_id.join(" ")
  end

  test "disable_restart" do
    assert_equal \
      "docker update --restart=no dash-proxy",
      new_command.disable_restart.join(" ")
  end

  test "drain" do
    assert_equal \
      "docker exec dash-proxy dash-proxy drain --drain-timeout=30s",
      new_command.drain(timeout: 30).join(" ")
  end

  test "wait_for_exit" do
    assert_equal \
      "docker wait dash-proxy",
      new_command.wait_for_exit.join(" ")
  end

  test "remove_stopped_container" do
    assert_equal \
      "docker container rm dash-proxy-next",
      new_command.remove_stopped_container(name: "dash-proxy-next").join(" ")
  end

  test "promote_next_container" do
    assert_equal \
      "docker container rename dash-proxy-next dash-proxy",
      new_command.promote_next_container.join(" ")
  end

  test "list with a custom container name" do
    assert_equal \
      "docker exec dash-proxy-next dash-proxy list",
      new_command.list(name: "dash-proxy-next").join(" ")
  end

  # Certificate store transfer (dash proxy export_certs / import_certs). The
  # apps-config bind mount is the one container path that is also a host path,
  # so exported archives travel through it.

  test "export certs through the running proxy" do
    assert_equal \
      "docker exec dash-proxy dash-proxy export certs /home/dash-proxy/.apps-config/certs-export.tar.gz",
      new_command.export_certs.join(" ")
  end

  test "export certs offline via a one-off container" do
    @config[:proxy] = { "run" => { "log_max_size" => "10m" } }

    assert_equal \
      "docker run --rm --volume dash-proxy-config:/home/dash-proxy/.config/dash-proxy " \
      "--volume $PWD/.dash/proxy/apps-config:/home/dash-proxy/.apps-config " \
      "ghcr.io/zoolutions/dash-proxy:#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION} " \
      "dash-proxy export certs /home/dash-proxy/.apps-config/certs-export.tar.gz",
      new_command.export_certs_offline.join(" ")
  end

  test "export certs offline falls back to the boot config image without a run config" do
    assert_equal \
      "docker run --rm --volume dash-proxy-config:/home/dash-proxy/.config/dash-proxy " \
      "--volume $PWD/.dash/proxy/apps-config:/home/dash-proxy/.apps-config " \
      "$(cat .dash/proxy/image 2> /dev/null || echo \"ghcr.io/zoolutions/dash-proxy\"):" \
      "$(cat .dash/proxy/image_version 2> /dev/null || echo \"#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION}\") " \
      "dash-proxy export certs /home/dash-proxy/.apps-config/certs-export.tar.gz",
      new_command.export_certs_offline.join(" ")
  end

  # The source streams through stdin into the one-off container: a bind mount
  # would need host permissions the container user cannot be guaranteed to
  # have, and the store must be written as the image's own user.
  test "import certs from a traefik acme.json" do
    @config[:proxy] = { "run" => { "log_max_size" => "10m" } }

    assert_equal \
      "docker run --rm --interactive --volume dash-proxy-config:/home/dash-proxy/.config/dash-proxy " \
      "ghcr.io/zoolutions/dash-proxy:#{Dash::Configuration::Proxy::Run::MINIMUM_VERSION} " \
      "sh -c 'cat > /tmp/kamal-cert-import && dash-proxy import certs --traefik-acme=\"/tmp/kamal-cert-import\"' " \
      "< .dash/proxy/certs-import",
      new_command.import_certs(traefik_acme: true).join(" ")
  end

  test "import certs with a resolver" do
    @config[:proxy] = { "run" => { "log_max_size" => "10m" } }

    assert_match "dash-proxy import certs --traefik-acme=\"/tmp/kamal-cert-import\" --resolver=\"letsencrypt\"",
      new_command.import_certs(traefik_acme: true, resolver: "letsencrypt").join(" ")
  end

  # An apostrophe in a resolver name must not break out of the single-quoted
  # sh -c payload on the remote host - Base#shell escapes it as '\''.
  test "import certs escapes an apostrophe in the resolver" do
    @config[:proxy] = { "run" => { "log_max_size" => "10m" } }

    command = new_command.import_certs(traefik_acme: true, resolver: "le'x").join(" ")

    assert_includes command, %q(--resolver="le'\\''x")
    assert_not_includes command, %q(--resolver="le'x")
  end

  test "import certs restores an archive with force" do
    @config[:proxy] = { "run" => { "log_max_size" => "10m" } }

    assert_match "dash-proxy import certs --archive=\"/tmp/kamal-cert-import\" --force",
      new_command.import_certs(force: true).join(" ")
  end

  test "import certs verifies an archive" do
    @config[:proxy] = { "run" => { "log_max_size" => "10m" } }

    assert_match "dash-proxy import certs --archive=\"/tmp/kamal-cert-import\" --verify",
      new_command.import_certs(verify: true).join(" ")
  end

  test "cert transfer paths and cleanup" do
    assert_equal ".dash/proxy/apps-config/certs-export.tar.gz", new_command.certs_archive_host_path
    assert_equal ".dash/proxy/certs-import", new_command.certs_import_host_path
    assert_equal "rm .dash/proxy/apps-config/certs-export.tar.gz", new_command.remove_certs_archive.join(" ")
    assert_equal "rm .dash/proxy/certs-import", new_command.remove_certs_import.join(" ")
  end

  private
    def new_command
      Dash::Commands::Proxy.new(Dash::Configuration.new(@config, version: "123"), host: "1.1.1.1")
    end

  # --- Stage 3c migrations -------------------------------------------------

  # The guard is negated and leads the chain because shell && and || share
  # The chain must start with a program: SSHKit prefixes the first word with
  # /usr/bin/env, and `env !` exits 127 instead of negating — which is how
  # 4.0.0 skipped the copy on every host and booted proxies onto empty volumes.
  test "copy_legacy_config_volume leads with docker, never with shell negation" do
    command = new_command.copy_legacy_config_volume.join(" ")

    assert command.start_with?("docker volume inspect dash-proxy-config > /dev/null 2>&1 || ! docker volume inspect kamal-proxy-config > /dev/null 2>&1 || ( docker volume create dash-proxy-config && docker run"),
      "guard first, legacy check second, create-and-copy grouped last: #{command}"
    assert command.end_with?("'cp -a /from/. /to/' )"), command
    refute_match "|| true", command, "a failed copy must fail the deploy, not vanish into || true"
  end

  # `A || ! B || ( C && D )`: A true → skip; B absent → skip; else C && D.
  test "copy_legacy_config_volume is one chain with the copy grouped in a subshell" do
    command = new_command.copy_legacy_config_volume.join(" ")

    assert_equal 2, command.scan("||").size, command
    assert_equal 1, command.scan("&&").size, command
  end

  test "copy_legacy_config_volume copies the pre-rename volume verbatim" do
    command = new_command.copy_legacy_config_volume.join(" ")

    assert_match "docker volume inspect kamal-proxy-config", command
    assert_match "docker volume create dash-proxy-config", command
    assert_match "--volume kamal-proxy-config:/from", command
    assert_match "--volume dash-proxy-config:/to", command
    assert_match "cp -a /from/. /to/", command
    assert_match "--user root", command, "the image's own user cannot write the destination volume"
  end

  # A rename means the old container has to release ports 80/443 before the new
  # one can claim them; no port-holder handoff spans two container names.
  test "remove_legacy_container stops and removes the pre-rename container" do
    command = new_command.remove_legacy_container(timeout: 30).join(" ")

    assert_match "docker container inspect kamal-proxy > /dev/null 2>&1", command
    assert_match "docker container stop --time=30 kamal-proxy", command
    assert_match "docker container rm kamal-proxy", command
    assert command.end_with?("|| true"), "a host with no legacy container must not fail its deploy"
  end

  test "remove_legacy_holder_container removes the pre-rename port holder" do
    command = new_command.remove_legacy_holder_container.join(" ")

    assert_match "docker container inspect kamal-proxy-net", command
    assert_match "docker container rm --force kamal-proxy-net", command
    assert command.end_with?("|| true")
  end

  # --- Stage 3c: the bridge, folded into one guarded round trip (zoolutions/dash#160) ---

  test "legacy_rename skips the whole bridge behind a marker in the run directory" do
    command = new_command.legacy_rename.join(" ")

    assert command.start_with?("test -f .dash/proxy/.legacy-renamed || ( "),
      "a migrated host must decide with the marker, before any docker call: #{command}"
    assert command.end_with?(")"), command
  end

  test "legacy_rename runs the three bridge steps in the documented order" do
    command = new_command.legacy_rename.join(" ")

    bridge = command.index("docker network inspect kamal > /dev/null 2>&1")
    copy = command.index("docker volume inspect dash-proxy-config > /dev/null 2>&1")
    replace = command.index("docker container inspect kamal-proxy > /dev/null 2>&1 && docker container stop")
    holder = command.index("docker container inspect kamal-proxy-net")

    assert bridge, command
    assert copy && bridge < copy, "the network bridge has to land before the volume copy: #{command}"
    assert replace && copy < replace, "the volume copy has to land before the container is replaced: #{command}"
    assert holder && replace < holder, command
  end

  # Each builder already mixes && and || at one precedence level, so composing them
  # flat would re-associate across their internals - and the volume copy's guard is
  # exactly the chain 4.0.0 lost every host's routing table by getting wrong.
  test "legacy_rename isolates every composed step in its own subshell" do
    command = new_command.legacy_rename.join(" ")

    assert_match "( docker network inspect kamal > /dev/null 2>&1", command
    assert_match "&& ( docker volume inspect dash-proxy-config", command
    assert_match "&& ( docker container inspect kamal-proxy > /dev/null 2>&1", command
    assert_match "&& ( docker container inspect kamal-proxy-net", command
  end

  # The two removals end in `|| true`, so the chain's exit status says nothing about
  # whether the legacy container is actually gone. Ask docker instead.
  test "legacy_rename writes the marker only once both legacy containers are gone" do
    command = new_command.legacy_rename.join(" ")

    assert_match "( ! docker container inspect kamal-proxy > /dev/null 2>&1 " \
      "&& ! docker container inspect kamal-proxy-net > /dev/null 2>&1 " \
      "&& mkdir -p .dash/proxy && touch .dash/proxy/.legacy-renamed || true )", command
  end

  # A failed volume copy must still abort the boot: it is the one step whose failure
  # is not masked today, and recording it as migrated would strand the routing table.
  test "legacy_rename leaves the volume copy free to fail the boot" do
    copy = new_command.legacy_rename.join(" ")[/\( docker volume inspect dash-proxy-config.*?'cp -a \/from\/\. \/to\/' \) \)/m]

    assert copy, new_command.legacy_rename.join(" ")
    refute_match "|| true", copy, "a failed copy must fail the deploy, not vanish into || true"
  end

  # Step 3: the apps-config mkdir is a round trip the host pays anyway, and it reads
  # nothing the bridge writes - so a migrated host pays zero round trips for the bridge.
  test "prepare_boot carries the apps-config directory in the bridge round trip" do
    command = new_command.prepare_boot.join(" ")

    assert command.start_with?("test -f .dash/proxy/.legacy-renamed ||"), command
    assert command.end_with?(") && mkdir -p .dash/proxy/apps-config"),
      "`a || b && c` is `(a || b) && c`, so the mkdir runs either way: #{command}"
  end

  # One inspect for what used to be container_id, config_digest and version.
  test "inspect_state reads id, image and config digest in one format" do
    assert_equal \
      "docker inspect dash-proxy --format '{{.Id}} {{.Config.Image}} " \
      "{{ with index .Config.Labels \"org.dash.proxy-config-digest\" }}{{ . }}" \
      "{{ else }}{{ index .Config.Labels \"org.kamal.proxy-config-digest\" }}{{ end }}'",
      new_command.inspect_state.join(" ")
  end

  test "State parses the three fields and derives the version from the image tag" do
    state = Dash::Commands::Proxy::State.parse("abc123 ghcr.io/zoolutions/dash-proxy:v1.2.3 deadbeef\n")

    assert state.exists?
    assert_equal "abc123", state.id
    assert_equal "v1.2.3", state.version
    assert_equal "deadbeef", state.digest
  end

  # A registry host carries a port, so the tag is what follows the LAST colon -
  # the same rule `version`'s `awk -F: '{print $NF}'` applies.
  test "State reads the tag past a registry port" do
    state = Dash::Commands::Proxy::State.parse("abc123 registry:4443/ghcr.io/zoolutions/dash-proxy:v1.2.3 deadbeef")

    assert_equal "v1.2.3", state.version
  end

  test "State of a host with no proxy container is empty, not an error" do
    state = Dash::Commands::Proxy::State.parse("")

    assert_not state.exists?
    assert_nil state.version
    assert_nil state.digest
  end

  # A container booted before the digest label existed inspects to a trailing blank
  # field - it has to read as "no digest", which is drift, not as a missing container.
  test "State of an unlabelled container exists but carries no digest" do
    state = Dash::Commands::Proxy::State.parse("abc123 ghcr.io/zoolutions/dash-proxy:v1.2.3 ")

    assert state.exists?
    assert_nil state.digest
  end
end
