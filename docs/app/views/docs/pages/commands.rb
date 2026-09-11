# frozen_string_literal: true

# The CLI reference — every visible command, from the Thor descriptions.
class Views::Docs::Pages::Commands < DocsUI::Page
  title "Commands"
  eyebrow "Reference"

  def lead = "The full dash CLI surface. Every command also answers --help."

  MAIN = [
    [ "dash setup", "Setup all accessories, push the env, and deploy app to servers" ],
    [ "dash deploy", "Deploy app to servers" ],
    [ "dash redeploy", "Deploy app without bootstrapping servers, starting the proxy, or pruning" ],
    [ "dash rollback [VERSION]", "Rollback app to VERSION" ],
    [ "dash details", "Show details about all containers" ],
    [ "dash audit", "Show audit log from servers" ],
    [ "dash config", "Show combined config (including secrets!)" ],
    [ "dash docs [SECTION]", "Show dash configuration documentation" ],
    [ "dash doctor", "Diagnose deploy readiness of servers, registry, proxy, ports, DNS, certificates, and per-role readiness gates" ],
    [ "dash init", "Create config stub in config/deploy.yml and secrets stub in .dash" ],
    [ "dash remove", "Remove the proxy, app, accessories, and registry session from servers" ],
    [ "dash migrate", "Move this project's .kamal directory to .dash" ],
    [ "dash upgrade", "Upgrade from Kamal 1.x to 2.0" ],
    [ "dash version", "Show dash version" ]
  ].freeze

  APP = [
    [ "boot", "Boot app on servers (or reboot app if already running)" ],
    [ "start / stop", "Start or stop existing app containers on servers" ],
    [ "exec [CMD...]", "Execute a custom command on servers within the app container" ],
    [ "logs", "Show log lines from app on servers" ],
    [ "details", "Show details about app containers" ],
    [ "containers / images", "Show app containers / images on servers" ],
    [ "stale_containers", "Detect app stale containers" ],
    [ "live / maintenance", "Switch the app between live and maintenance mode" ],
    [ "rollout <deploy|set|stop>", "Manage a canary rollout of a new version through the proxy — see Canary rollout" ],
    [ "remove", "Remove app containers and images from servers" ],
    [ "version", "Show app version currently running on servers" ]
  ].freeze

  PROXY = [
    [ "boot", "Boot proxy on servers" ],
    [ "boot_config <set|get|reset>", "Manage proxy boot configuration" ],
    [ "reboot", "Reboot proxy on servers (stop, remove, start new container)" ],
    [ "start / stop / restart", "Manage the existing proxy container on servers" ],
    [ "details", "Show details about proxy container from servers" ],
    [ "logs", "Show log lines from proxy on servers" ],
    [ "loadbalancer <info|start|stop|logs|deploy>", "Manage the load balancer" ],
    [ "cache <stats|purge>", "Manage the response cache" ],
    [ "domains <refresh|list|stats>", "Manage dynamic TLS domains" ],
    [ "export_certs LOCAL_PATH", "Export the TLS certificate store to a local archive (contains private keys)" ],
    [ "import_certs", "Import certificates from a Traefik acme.json or an exported archive" ],
    [ "remove", "Remove proxy container and image from servers" ]
  ].freeze

  ACCESSORY = [
    [ "boot [NAME]", "Boot new accessory service on host (NAME=all boots all)" ],
    [ "reboot [NAME]", "Reboot existing accessory on host" ],
    [ "start / stop / restart [NAME]", "Manage the existing accessory container" ],
    [ "details [NAME]", "Show details about accessory on host" ],
    [ "exec [NAME] [CMD...]", "Execute a custom command within the accessory container" ],
    [ "logs [NAME]", "Show log lines from accessory on host" ],
    [ "remove [NAME]", "Remove accessory container, image and data directory from host" ],
    [ "upgrade", "Upgrade accessories from Kamal 1.x to 2.0" ]
  ].freeze

  BUILD = [
    [ "deliver", "Build app and push app image to registry then pull image on servers" ],
    [ "push / pull", "Build and push the image to the registry / pull it onto servers" ],
    [ "create / remove / details", "Manage the buildx build setup" ],
    [ "dev", "Build the working directory, tag it as dirty, push to the local image store" ]
  ].freeze

  OTHERS = [
    [ "dash server bootstrap", "Set up Docker to run dash apps" ],
    [ "dash server exec", "Run a custom command on the server" ],
    [ "dash registry <setup|remove|login|logout>", "Manage the local registry or remote registry sessions" ],
    [ "dash lock <status|acquire|release>", "Manage the deploy lock; --server targets the shared server lock instead" ],
    [ "dash prune <all|images|containers>", "Prune old application images and stopped containers" ],
    [ "dash secrets <fetch|extract|print>", "Helpers for extracting secrets from a vault" ],
    [ "dash report [--last N]", "Print the last saved deploy report, or a trend over the last N" ],
    [ "dash report path", "Print the directory saved reports are written to" ]
  ].freeze

  def content
    everyday
    app_commands
    proxy_commands
    accessory_commands
    build_commands
    other_commands
  end

  private

  def everyday
    DocsUI::Section("Main commands") do
      command_table MAIN
      md <<~'MD'
        `setup` for the first deploy, `deploy` for every one after,
        `rollback` when it goes wrong, `doctor` when you are not sure it will
        go right. `dash docs` prints the same configuration reference the
        [Configuration](/docs/configuration) pages here are generated from.
        `migrate` renames a kamal project's `.kamal/` to `.dash/` — see
        [From kamal](/docs/from-kamal).

        `--rolling` on `upgrade`, `proxy reboot`, and `proxy upgrade` walks the
        hosts one at a time instead of in parallel — see
        [Rolling restarts](/docs/worker-roles#rolling-restarts).
      MD
    end
  end

  def app_commands
    DocsUI::Section("dash app", description: "Manage application containers.") do
      subcommand_table APP
    end
  end

  def proxy_commands
    DocsUI::Section("dash proxy", description: "Manage the proxy and its dash-only features.") do
      subcommand_table PROXY
      md <<~'MD'
        The `loadbalancer`, `cache`, `domains`, and `export_certs`/`import_certs`
        commands are dash-only — see [Load balancing](/docs/load-balancing),
        [Response caching](/docs/caching), and
        [SAN batching & wildcards](/docs/certificates).
      MD
    end
  end

  def accessory_commands
    DocsUI::Section("dash accessory", description: "Manage accessories (db/redis/search).") do
      subcommand_table ACCESSORY
    end
  end

  def build_commands
    DocsUI::Section("dash build", description: "Build the application image.") do
      subcommand_table BUILD
    end
  end

  def other_commands
    DocsUI::Section("server, registry, lock, prune, secrets, report") do
      command_table OTHERS
    end
  end

  def command_table(rows)
    DocsUI::Table(
      [ "Command", "What it does" ],
      rows.map { |command, description| [ [ :code, command ], description ] }
    )
  end

  def subcommand_table(rows)
    DocsUI::Table(
      [ "Subcommand", "What it does" ],
      rows.map { |command, description| [ [ :code, command ], description ] }
    )
  end
end
