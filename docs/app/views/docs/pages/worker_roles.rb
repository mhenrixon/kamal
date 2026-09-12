# frozen_string_literal: true

# Non-proxied roles (job supervisors, message listeners): why readiness_delay is
# not a gate, the supervisor-serves-/readyz pattern, and how the pieces of a
# gapless worker deploy fit together. Key-by-key detail lives in the generated
# Roles and Booting references; this page links there rather than restating it.
class Views::Docs::Pages::WorkerRoles < DocsUI::Page
  title "Worker roles"
  eyebrow "Deploying"

  def lead = "Readiness and rolling restarts for roles that do not sit behind the proxy."

  def content
    not_a_gate
    supervisor_readyz
    listener_everywhere
    stop_budget
    rolling
    exec_probes
    checking
  end

  private

  def not_a_gate
    DocsUI::Section("Why readiness_delay is not a health gate") do
      md <<~'MD'
        A role behind the proxy has a real readiness gate: dash-proxy probes the
        new container and only switches traffic once it answers. A role that is
        **not** proxied — a job supervisor, a message listener, anything without
        an HTTP front — gets a different boot sequence:

        1. start the new container;
        2. wait until it counts as ready;
        3. stop the old container.

        What "counts as ready" means in step 2 depends on what the role declares.
        dash reports it as the role's **readiness source**, in the deploy banner
        and in `dash doctor`:

        | Readiness source | What step 2 waits for |
        |---|---|
        | `dash-proxy health check /up` | the proxy's own probe (proxied roles only) |
        | `healthcheck /readyz:7433` or `healthcheck (custom cmd)` | docker's HEALTHCHECK reports `healthy` |
        | `healthcheck exec probe (…)` | the probe, run by the deploy host, exits 0 |
        | `docker healthcheck (options: health-cmd)` | docker's HEALTHCHECK reports `healthy` |
        | `NONE (old container stops 7s after boot)` | the container is still *running* after `readiness_delay` seconds |

        The last row is the trap. With no healthcheck, docker can only tell dash
        that the container is running, so dash sleeps for `readiness_delay`
        (default 7s), checks it is still running, and stops the old container.
        A supervisor that takes twelve seconds to boot Rails and fork its
        children passes that check while it is still loading — and for a moment
        nothing is consuming the queue. A container that crashes on second nine
        passes it too.

        That is why a non-proxied role with no readiness decision warns on every
        deploy. The choices are to declare a `healthcheck:` (the rest of this
        page) or to accept the gap explicitly with `healthcheck: false`, which
        silences the warning without changing the behaviour.
      MD
      DocsUI::Callout(:note) do
        plain "The readiness delay still applies to roles that "
        em { "do" }
        plain " declare a healthcheck — but only as a floor after the container reports healthy, never as a substitute for it. "
        plain "Every key on this page is documented in the "
        a(href: "/docs/role") { "Roles reference" }
        plain "."
      end
    end
  end

  def supervisor_readyz
    DocsUI::Section("A supervisor that answers /readyz") do
      md <<~'MD'
        The pattern that makes a worker deploy gapless: the supervisor process
        serves a **container-local readiness endpoint**, and a docker
        healthcheck polls it. Nothing is published to the host network; the
        probe runs inside the container.

        The endpoint's contract is what matters:

        - `200` only when *this* container's children are alive and consuming —
          not when the process has merely started, and not when some other
          replica is healthy.
        - `503` for every other state. Giving the states names (`BOOTING`,
          `OK`, `DEGRADED`, `DRAINING`) makes the health log readable when a
          boot fails: `DRAINING` in particular tells you the old container was
          probed after it had already been told to stop.
        - The probe itself is a tiny binary that hits the endpoint and exits
          non-zero on anything but `200`. Docker runs it every `interval`
          seconds for the container's whole life, so it **must not boot the
          app** — a probe that loads Rails to check Rails is a probe that eats a
          core.

        A supervisor role built that way, with the process listening on a port
        the probe reads from the environment:
      MD
      DocsUI::Code(<<~YAML, filename: "config/deploy.yml", lexer: :yaml)
        servers:
          web:
            hosts:
              - 10.0.0.1
              - 10.0.0.2
          pgbus:
            hosts:
              - 10.0.0.3
            cmd: bin/pgbus start
            healthcheck:
              cmd: bin/pgbus-health
              interval: 5
              timeout: 5
              retries: 3
              start_period: 60
            env:
              clear:
                PGBUS_HEALTH_PORT: 7433
            stop_timeout: 45

        deploy_timeout: 120
      YAML
      md <<~'MD'
        Read it against the boot sequence: docker starts probing five seconds
        in, ignores failures for the first sixty (`start_period`), and marks the
        container `healthy` on the first `200`. dash waits on docker's verdict
        until `deploy_timeout`, then stops the old container — which is
        told to stop and given `stop_timeout` seconds to finish. Three straight
        failures after the start period mark it `unhealthy`, and a boot that
        never reaches `healthy` fails with the container log and the probe
        history, leaving the old container running.

        If the image has `curl`, the same gate needs no probe binary — dash
        builds the `curl -f http://localhost:<port><path>` check for you:
      MD
      DocsUI::Code(<<~YAML, filename: "config/deploy.yml", lexer: :yaml)
        healthcheck:
          port: 7433
          path: /readyz
          interval: 5
          timeout: 5
          retries: 3
          start_period: 60
      YAML
      md <<~'MD'
        And the same thing again as raw docker flags, for anyone who was already
        doing this by hand before `healthcheck:` existed:
      MD
      DocsUI::Code(<<~YAML, filename: "config/deploy.yml", lexer: :yaml)
        options:
          health-cmd: bin/pgbus-health
          health-interval: 5s
          health-timeout: 5s
          health-retries: 3
          health-start-period: 60s
      YAML
      DocsUI::Callout(:note) do
        plain "The "
        code { "options: health-cmd:" }
        plain " form gates the deploy identically (readiness source "
        code { "docker healthcheck (options: health-cmd)" }
        plain "). What it loses is the vocabulary: "
        code { "dash doctor" }
        plain " and the deploy banner cannot name the port or path, durations must be written as docker strings, and it cannot be combined with a "
        code { "healthcheck:" }
        plain " block. Prefer "
        code { "healthcheck:" }
        plain " for new roles."
      end
    end
  end

  def listener_everywhere
    DocsUI::Section("A listener on every app host") do
      md <<~'MD'
        The second shape is a role that **shares hosts with web**: a message
        listener that should run wherever the app runs, so each host consumes
        its own share and losing a host loses nothing. Two things change from
        the supervisor case.

        **Readiness means subscribed, not started.** A listener that has
        connected but not yet subscribed is not ready; neither is one whose
        subscription silently lapsed. The probe should prove the subscriptions
        by publishing a no-op and waiting for it to flush through — a round
        trip that only succeeds when the whole path (connection, subscription,
        handler) is live. When every listener is in the same queue group, any
        number of them can be up at once: the broker delivers each message to
        exactly one member, so the overlap between the old and new container
        during a deploy is safe rather than a duplicate-delivery window.

        **Bound the connection pool per role.** A role on every app host
        multiplies whatever pool size the image defaults to by the host count;
        a listener rarely needs more than a couple of threads, so scope it in
        the role's env rather than the app's:
      MD
      DocsUI::Code(<<~YAML, filename: "config/deploy.yml", lexer: :yaml)
        servers:
          web:
            hosts:
              - app-1
              - app-2
              - app-3
          listener:
            hosts:
              - app-1
              - app-2
              - app-3
            cmd: bin/sava-listener
            healthcheck:
              cmd: bin/sava-listener-health
              interval: 5
              timeout: 5
              retries: 3
              start_period: 60
            env:
              clear:
                SAVA_HEALTH_PORT: 7434
                RAILS_MAX_THREADS: 2
            stop_timeout: 45
      YAML
      md <<~'MD'
        Because the listener shares hosts with the primary role, its boot waits
        behind web's — see [Rolling restarts](#rolling-restarts) below for the
        barrier that enforces that.
      MD
    end
  end

  def stop_budget
    DocsUI::Section("The stop-timeout budget") do
      md <<~'MD'
        The new container is healthy; now the old one has to leave without
        dropping work. That is a budget with three nested deadlines, and the
        deploy only stays gapless if they nest in the right order:

        | Deadline | Who owns it | Must be |
        |---|---|---|
        | `stop_timeout` | dash → `docker stop -t` | the largest: after it, docker sends `SIGKILL` |
        | supervisor shutdown deadline | your supervisor, on `SIGTERM` | smaller than `stop_timeout`, larger than the drain |
        | drain window | each child: finish the in-flight job, ack, exit | the smallest |

        Put differently: `stop_timeout > supervisor shutdown deadline > drain
        window`. Invert any pair and the outer layer kills the inner one
        mid-job. A supervisor that gives its children 30s and itself 40s wants
        `stop_timeout: 45`, not the 10s docker default — which is exactly what
        an unproxied role with no `stop_timeout` gets, since the root
        `drain_timeout` (default 30s) is only used as the fallback.

        `deploy_timeout` is the other budget, on the way *in*. dash gives up
        waiting for `healthy` after it, so it must cover the whole boot: Rails
        load, supervisor start, children forked, plus the healthcheck's own
        `start_period`. The 30s default is sized for a web container behind the
        proxy; a supervisor that needs 60s of `start_period` needs a
        `deploy_timeout` comfortably above that — the examples above use 120.
        Both keys are documented in the
        [deploy.yml reference](/docs/configuration).
      MD
    end
  end

  def rolling
    DocsUI::Section("Rolling restarts") do
      md <<~'MD'
        By default dash boots the new version on every host in parallel. Four
        controls pace that, from widest to narrowest:

        - **The barrier.** On every deploy, non-primary roles wait until the
          *first* primary-role container reports healthy before they boot at
          all. If that first container fails, nothing else starts and the deploy
          stops with the old containers still running. The listener above rides
          this for free: web proves the image boots before any listener is
          replaced.
        - **`boot: { limit, wait }` at the root** slices the combined host list
          of every role into groups — a whole-deploy setting. See
          [Booting](/docs/boot).
        - **`boot:` on a role** paces that role's hosts on their own:
          `limit: 1` walks them one at a time, `wait:` pauses between them,
          while sibling roles still boot in parallel. This is what turns a
          two-host worker role into actual redundancy. It needs role-first
          iteration (`boot/parallel_roles`), which dash switches on for you.
        - **`--rolling`** on `dash upgrade`, `dash proxy reboot`, and
          `dash proxy upgrade` walks hosts in sequence for that one command.
      MD
      DocsUI::Code(<<~YAML, filename: "config/deploy.yml", lexer: :yaml)
        servers:
          pgbus:
            hosts:
              - 10.0.0.3
              - 10.0.0.4
            boot:
              limit: 1
              wait: 15
      YAML
    end
  end

  def exec_probes
    DocsUI::Section("exec probes") do
      md <<~'MD'
        `healthcheck: exec:` is the escape hatch for an image whose
        `HEALTHCHECK` you cannot change, or for an emergency override with no
        rebuild. Instead of configuring docker's healthcheck, dash `docker
        exec`s the probe on the deploy host once a second and gates the boot on
        its exit code. It may use `${...}` (quoted through to the container),
        which `cmd` may not.

        It is strictly worse than `cmd` in the general case: deploy-time only
        (docker never runs it, `docker ps` never shows `(healthy)`), a process
        spawn on the host per attempt, and it cannot be combined with `cmd`,
        `port`, `path`, or any duration key. The trade-offs are spelled out
        under `healthcheck` in the [Roles reference](/docs/role).
      MD
      DocsUI::Code(<<~YAML, filename: "config/deploy.yml", lexer: :yaml)
        healthcheck:
          exec: bin/ready-check
      YAML
    end
  end

  def checking
    DocsUI::Section("Checking it") do
      md <<~'MD'
        You never have to infer which gate a role has. `dash doctor` prints one
        readiness line per role, and every `dash deploy` opens with the same
        line in its banner — yellow when the answer is `NONE`:
      MD
      DocsUI::Code(<<~TEXT, lexer: :plaintext)
        Deploying app (version 3f9c2a1)
          web: 3 hosts (app-1, app-2, app-3) — readiness: dash-proxy health check /up
          pgbus: 1 host (10.0.0.3) — readiness: healthcheck (custom cmd)
          listener: 3 hosts (app-1, app-2, app-3) — readiness: healthcheck (custom cmd)
      TEXT
      md <<~'MD'
        A role that declares a healthcheck whose flags never reached docker
        (`docker inspect` shows no `Healthcheck`) fails the boot rather than
        passing on the readiness delay alone — the deploy would otherwise be
        accepted without ever probing the container.
      MD
    end
  end
end
