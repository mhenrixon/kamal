# frozen_string_literal: true

# Every hook dash fires, when, with which environment — including the dash-only
# proxy-deploy and loadbalancer-reboot hooks kamal-deploy.org cannot document.
class Views::Docs::Pages::Hooks < DocsUI::Page
  title "Hooks"
  eyebrow "Deploying"

  def lead = "Executable files in .dash/hooks that dash runs before and after each stage of a deploy."

  HOOKS = [
    [ "pre-connect", "before the first SSH connection of any command that talks to the servers", "any", "yes", "" ],
    [ "pre-build", "before the image is built", "build push / deliver, deploy, setup", "", "" ],
    [ "pre-deploy", "before the deploy starts, after the lock is taken", "deploy, redeploy, rollback, setup", "yes", "" ],
    [ "post-deploy", "after a successful deploy, with the elapsed time", "deploy, redeploy, rollback, setup", "yes", "" ],
    [ "pre-app-boot", "before each boot group of hosts starts its new containers", "app boot, deploy, redeploy, rollback", "", "" ],
    [ "post-app-boot", "after that boot group's new containers are live", "app boot, deploy, redeploy, rollback", "", "" ],
    [ "pre-proxy-deploy", "before a proxied role's new container is registered with dash-proxy on a host", "app boot, deploy, redeploy, rollback", "", "dash" ],
    [ "post-proxy-deploy", "after dash-proxy reports that container healthy and switches to it", "app boot, deploy, redeploy, rollback", "", "dash" ],
    [ "pre-app-stop", "before the previous version's container is stopped on a host", "app boot, deploy, redeploy, rollback", "", "" ],
    [ "post-app-stop", "after it is stopped", "app boot, deploy, redeploy, rollback", "", "" ],
    [ "pre-proxy-reboot", "before the proxy container is replaced on a host", "proxy reboot, proxy boot (config drift), upgrade", "", "" ],
    [ "post-proxy-reboot", "after the new proxy container is up", "proxy reboot, proxy boot (config drift), upgrade", "", "" ],
    [ "pre-loadbalancer-reboot", "before the load balancer container is replaced", "proxy reboot, proxy boot (config drift)", "", "dash" ],
    [ "post-loadbalancer-reboot", "after the new load balancer container is up", "proxy reboot, proxy boot (config drift)", "", "dash" ],
    [ "docker-setup", "after Docker is confirmed installed on every host", "server bootstrap, setup", "", "" ]
  ].freeze

  def content
    overview
    the_hooks
    environment
    configuration
    example
  end

  private

  def overview
    DocsUI::Section("How hooks run") do
      md <<~'MD'
        A hook is an executable file named after the event, in `.dash/hooks`
        (or `hooks_path`). dash runs it **locally** on the machine running the
        command, with the event's details in the environment, and treats a
        non-zero exit as a failure — a failing `pre-*` hook aborts the
        command. The exceptions are `pre-app-stop` / `post-app-stop`: by then
        the new container is already live, so a failure there is reported and
        the old container is stopped anyway.

        `dash init` writes commented sample hooks for the common events. Pass
        `--skip-hooks` to any command to run it without them.
      MD
    end
  end

  def the_hooks
    DocsUI::Section("The hooks") do
      DocsUI::Table(
        [ "Hook", "Fires", "Commands", "Secrets", "" ],
        HOOKS.map { |name, fires, commands, secrets, origin| [ [ :code, name ], fires, commands, secrets, origin.empty? ? "" : "dash-only" ] }
      )
      md <<~'MD'
        `pre-proxy-deploy` / `post-proxy-deploy` fire once per host and role,
        around the exact moment dash-proxy switches traffic — the place to warm
        a cache or notify a tracker with the host that just went live. The
        loadbalancer hooks wrap the [load balancer](/docs/load-balancing)
        container's replacement, which happens separately from the per-host
        proxies. Neither exists in upstream kamal.

        `pre-connect` runs before the first SSH connection of a command, so it
        fires for `dash app logs` as much as for `dash deploy`; use
        `DASH_COMMAND` to scope it. `pre-traefik-reboot` / `post-traefik-reboot`
        from kamal 1 are rejected at config time — rename them to the proxy
        hooks.
      MD
    end
  end

  def environment
    DocsUI::Section("Environment") do
      md <<~'MD'
        Every hook gets these variables. Each is emitted twice — as `DASH_*`
        and, until dash 5.0, as its `KAMAL_*` twin with the same value, so hooks
        written for kamal keep working.

        | Variable | Value |
        |---|---|
        | `DASH_RECORDED_AT` | UTC timestamp of the event |
        | `DASH_PERFORMER` | the git email of whoever is running dash, or the local username |
        | `DASH_SERVICE` | the `service` from deploy.yml |
        | `DASH_SERVICE_VERSION` | `service@abbreviated version` |
        | `DASH_VERSION` | the full version being deployed |
        | `DASH_DESTINATION` | the `-d` destination, when one is set |
        | `DASH_HOSTS` | comma-separated hosts the event concerns (the boot group, the single host, or the whole target) |
        | `DASH_ROLES` | comma-separated roles, when the command was narrowed with `--roles` |
        | `DASH_ROLE` | the one role, on the proxy-deploy hooks |
        | `DASH_COMMAND` / `DASH_SUBCOMMAND` | the command being run, e.g. `deploy`, or `app` / `boot` |
        | `DASH_LOCK` | `true` when the command holds the deploy lock |
        | `DASH_RUNTIME` | seconds elapsed, on `post-deploy` |

        `post-deploy` also gets what the [deploy report](/docs/deploy-report)
        measured, so a hook can page on a build that doubled without parsing
        anything:

        | Variable | Value |
        |---|---|
        | `DASH_BUILD_RUNTIME` | seconds the build phase took — absent when nothing was built |
        | `DASH_BOOT_RUNTIME` | seconds the boot phase took — absent when nothing was booted |
        | `DASH_ADVICE_COUNT` | how many pieces of advice the report printed |
        | `DASH_ADVICE_WARNINGS` | how many of those were warnings rather than notes |
        | `DASH_REPORT_PATH` | the JSON report this deploy saved, when `report: history:` is not `0` |

        Under `dash setup` the hook fires from the `deploy` it wraps, before the
        outer report is finalised, so `DASH_REPORT_PATH` is absent from that run.

        Hooks marked **Secrets** in the table also receive every entry of
        `.dash/secrets` as environment variables, so a `pre-deploy` hook can
        talk to the same services the deploy does.
      MD
    end
  end

  def configuration
    DocsUI::Section("Configuration") do
      md <<~'MD'
        Two keys in `deploy.yml`, both documented in the
        [deploy.yml reference](/docs/configuration):

        - `hooks_path` — where the hook files live. Defaults to `.dash/hooks`
          (`.kamal/hooks` is still read when only that exists).
        - `hooks_output` — `quiet` or `verbose`, globally or per hook, to
          control whether a hook's stdout is shown. `-v` / `-q` on the command
          line override it, and a failed hook always shows its output.
      MD
      DocsUI::Code(<<~YAML, filename: "config/deploy.yml", lexer: :yaml)
        hooks_output:
          pre-build: quiet
          post-deploy: verbose
      YAML
    end
  end

  def example
    DocsUI::Section("A pre-deploy hook") do
      md <<~'MD'
        The classic: refuse to deploy from a dirty tree, and record the deploy
        somewhere. Make the file executable (`chmod +x`).
      MD
      DocsUI::Code(<<~SHELL, filename: ".dash/hooks/pre-deploy", lexer: :shell)
        #!/bin/sh
        set -e

        if [ -n "$(git status --porcelain)" ]; then
          echo "Refusing to deploy with uncommitted changes" >&2
          exit 1
        fi

        echo "$DASH_PERFORMER is deploying $DASH_SERVICE_VERSION to $DASH_HOSTS"
      SHELL
    end
  end
end
