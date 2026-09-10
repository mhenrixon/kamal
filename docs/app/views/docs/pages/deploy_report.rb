# frozen_string_literal: true

# The table, the build rows and the Advice block every deploy prints — what each
# column means, and what every rule id is telling you to change.
class Views::Docs::Pages::DeployReport < DocsUI::Page
  title "Reading the deploy report"
  eyebrow "Deploying"

  def lead = "Every deploy prints where its time went and what to change about your Dockerfile. No flag, no extra commands."

  def content
    anatomy
    phase_table
    build_rows
    advice_block
    rules
    silencing
  end

  private

  def anatomy
    DocsUI::Section("What prints") do
      md <<~'MD'
        `deploy`, `redeploy`, `setup`, `rollback` and a standalone `build push`
        all end with the same report. Nothing about it is opt-in, and none of it
        costs an extra SSH round trip or an extra `docker` command: the phase
        times come from the clock, the build steps are parsed out of the buildx
        output dash already streams, and the advice is read off your Dockerfile
        on the machine you deployed from.
      MD
      DocsUI::Code(<<~TEXT, lexer: :text)
        Finished all in 196.2 seconds
          Startup (load, config)                  0.9s
          Validate config and secrets             2.1s
          Build and push app image              140.0s
            build context                                                   3.2s (356.5MB)
            [build 5/9] RUN bundle install                                 84.1s
            cached steps                                                  9 of 14
            export + push                                                  41.4s (cache export 29.4s)
          Acquire deploy lock                     0.3s   2 ssh     0.2s
          Boot                                   55.2s  12 ssh    41.0s
            web 10.0.0.1                         55.0s   6 ssh    20.4s (healthy after 31.2s)
          Advice
            warn  Dockerfile:14   COPY . . runs before `bundle install` (line 21), so dependencies reinstall on every commit (measured 84.1s uncached)
                                  → copy the dependency manifests first (Gemfile, package.json, lockfiles), install, then copy the rest of the tree
            info  builder.cache   exporting the build cache took 29.4s of 140.0s with mode=max
                                  → try mode=min under builder: cache: options:
      TEXT
    end
  end

  def phase_table
    DocsUI::Section("The phase table") do
      md <<~'MD'
        One row per phase, in the order they started, indented under the phase
        that contains them. After the seconds, a phase that talked to a server
        shows what that cost:

        - **`12 ssh`** — how many commands dash ran over SSH while that phase was
          current, including the ones its child rows ran. `local` in place of
          `ssh` means the commands ran on the deploying machine (a build, mostly).
        - **`41.0s`** — how much of the phase's wall time was spent inside those
          commands. A phase whose seconds are much larger than its time-in-SSH
          was waiting on something else: a health check, a lock, a sleep.

        `Startup (load, config)` covers everything before the first phase could be
        timed — loading the gem, parsing `deploy.yml`, resolving secrets adapters.
        It is the one row you cannot change from `deploy.yml`, which is exactly
        why it is printed.
      MD
    end
  end

  def build_rows
    DocsUI::Section("The build rows") do
      md <<~'MD'
        Under the build phase, what the build itself spent its time on:

        - **`build context`** — how many bytes were shipped to the builder before
          the first instruction ran, and how long that took. Decimal units, the
          same ones buildx prints.
        - **The five slowest uncached steps** — labelled the way buildx labelled
          them (`[build 5/9] RUN bundle install`), so you can match a row to a
          line in your Dockerfile. Cached steps cost nothing and are not listed.
        - **`cached steps`** — how many of your own Dockerfile steps came from the
          cache. BuildKit's own bookkeeping (metadata lookups, auth tokens) is not
          counted, because you cannot do anything about it.
        - **`export + push`** — exporting the image and pushing it to the registry,
          with the cache export called out separately when there is one.

        A build that fails prints the same rows plus the step that broke. A
        `pack` (Cloud Native Buildpacks) build prints none of them: buildpacks
        emit no per-step progress to read.
      MD
    end
  end

  def advice_block
    DocsUI::Section("The Advice block") do
      md <<~'MD'
        Below the table, what dash would change about your Dockerfile and your
        build context. Each finding names a severity, where to look, what is
        wrong, and — on the line under it — what to do instead.

        Some rules are **measured**: they only fire when a build actually ran, and
        they quote its numbers. "Your `COPY . .` busts the bundle install" is a
        hint; "…and that install cost 84.1 seconds in this build" is a decision.

        Advice is never in the deploy's way. It runs after the image is delivered
        and before the boot, so it prints even when the boot fails, and anything
        that goes wrong inside it costs one yellow `Deploy report unavailable`
        line and nothing else.

        The same rules — the static ones, without the measurements — run under
        `dash doctor`, so you can read them before a deploy rather than after.
      MD
    end
  end

  def rules
    DocsUI::Section("The rules") do
      md <<~'MD'
        Every finding carries a rule id. Measured rules are marked ⏱.

        | Rule | What it means |
        |---|---|
        | `copy-before-install` ⏱ | A copy of the whole tree runs before a dependency install, so every commit reinstalls. Copy the manifests and lockfiles first. |
        | `context-size` ⏱ | The build shipped more than 50 MB of context before it started. Trim it with `.dockerignore` or point `builder: context:` somewhere smaller. |
        | `missing-dockerignore` | The build context has no `.dockerignore`, so all of it goes to the builder. |
        | `dockerignore-gaps` ⏱ | The `.dockerignore` misses `.git`, or a directory that is actually in the context (`node_modules`, `tmp`, `log`, `storage`, `coverage`, `.env*`). Becomes a warning when the measured context is large. |
        | `latest-base` | A `FROM` with no tag or `:latest`. A digest or an ARG-interpolated tag counts as pinned. |
        | `secret-in-build-arg` | An `ARG` or `ENV` named like a credential. Build args live in the image history forever — use `--mount=type=secret` with `builder: secrets:`. |
        | `single-stage-build-deps` | The only stage installs compilers or `-dev` packages, which then ship. Split build from runtime. |
        | `apt-hygiene` | An `apt-get install` in a shipped stage without `--no-install-recommends`, or that leaves `/var/lib/apt/lists` behind. |
        | `cache-busting-arg` | An `ARG` that changes every commit (a SHA, a build timestamp) is referenced before the dependency install, invalidating it every time. |
        | `cache-export-cost` ⏱ | Exporting the build cache took more than a fifth of the build, with `mode=max`. |
        | `curl-pipe-shell` | A download piped straight into a shell. Pin a version and verify a checksum. |
        | `inline-env-blob` | More than twenty inline `KEY=value` assignments in front of one command, so editing any of them rebuilds the layer. |
        | `no-cache-mount` | A dependency install without `--mount=type=cache`. The suggestion names the directory your package manager expects. |
        | `uncached-install` ⏱ | An install missed the cache and cost real time, and no broad copy above it explains why. |
        | `root-user` | The final stage has no `USER`, so the container runs as root. |
      MD
    end
  end

  def silencing
    DocsUI::Section("Turning it down") do
      md <<~'MD'
        The `report:` key controls the advice. The table itself always prints.
      MD
      DocsUI::Code(<<~YAML, lexer: :yaml)
        report:
          advice: true          # print the Advice block at all
          hadolint: auto        # also run hadolint when it is on PATH; false to never
          ignore:
            - root-user         # any rule id above, or a hadolint code like DL3008
      YAML
      md <<~'MD'
        With `hadolint: auto`, dash runs `hadolint --format json --no-fail` on the
        same file when the binary is on your `PATH` and folds its findings in
        under their own codes. Its exit status never touches the deploy, and if
        it cannot run you get one informational line instead.

        See [Deploy report](/docs/report) for the full configuration reference.
      MD
    end
  end
end
