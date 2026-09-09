# Coding Style Rules

## File Organization

**MANY SMALL FILES > FEW LARGE FILES**

- High cohesion, low coupling
- 200-400 lines typical
- 800 lines maximum per file
- Extract complex logic to dedicated classes under `lib/dash/`
- Organize by layer (`cli`, `commander`, `commands`, `configuration`) — see the layer cake in `CLAUDE.md`

## Ruby Style

### Classes & Methods

```ruby
# Good: small, focused Thor command delegating to Commands/Configuration
desc "start", "Start existing proxy container on servers"
def start
  modify(lock: true) do
    on(DASH.proxy_hosts) do |host|
      execute *DASH.auditor.record("Started proxy"), verbosity: :debug
      execute *DASH.proxy(host).start
    end
  end
end

# Bad: business logic and SSH orchestration inlined in one giant method
def start
  # 150 lines mixing option parsing, docker command building, and on() blocks...
end
```

Keep the layers separate: `Dash::Cli::*` parses options and orchestrates `on()`/`modify()` blocks; `Dash::Commands::*` builds docker/shell argument arrays (pure, no SSH); `Dash::Configuration::*` turns `deploy.yml` into objects. Don't build docker args in a CLI command or run SSHKit calls from a Commands class.

### Error Handling

```ruby
# Good: rescue the specific SSHKit/Docker error, re-raise anything else
on(DASH.hosts) do |host|
  execute *DASH.docker.create_network
rescue SSHKit::Command::Failed => e
  raise unless e.message.include?("already exists")
end

# Bad: swallowing everything
on(DASH.hosts) do |host|
  execute *DASH.docker.create_network
rescue StandardError
  nil
end
```

### Commands build argv arrays, not shell strings

```ruby
# Good: Dash::Commands::* returns argument arrays; SSHKit / execute splats them
def run_command
  [ "kamal-proxy", "run", *optionize(run_command_options) ].join(" ")
end

execute *DASH.proxy(host).start_or_run

# Bad: hand-built shell strings that skip Dash::Utils#argumentize/#optionize
execute "docker run --name kamal-proxy #{flags.join(' ')}"
```

Use `argumentize` / `optionize` (delegated from `Dash::Utils`) for flag arrays — see `lib/dash/configuration/proxy/run.rb` for the pattern.

### Thread Safety

```ruby
# Good: on() parallelizes across hosts via SSHKit's own thread pool — no shared
# mutable state needed inside the block
on(DASH.proxy_hosts) do |host|
  execute *DASH.proxy(host).stop, raise_on_non_zero_exit: false
end

# Bad: mutating a shared array/hash from inside on() without synchronization
results = []
on(DASH.proxy_hosts) { |host| results << host } # race condition
```

If you must accumulate results across hosts, use `SSHKit::Backend::Abstract#capture_with_info` per host and merge outside the block, or guard shared state with `Mutex#synchronize`.

## Fork-specific rules

These are on top of the general rules above — see `CLAUDE.md` and `.claude/rules/upstream-sync.md` for the full list.

- **The gemspec is `dash.gemspec`** and releases go through `bin/release` (a wrapper around `rake release[X.Y.Z]`) — the upstream-owned duplicates (`kamal.gemspec`, the upstream `bin/release`, `bin/kamal`) were deleted in the 2026-08 clean break; today's `bin/release` is dash-owned.
- **Interpolate `Dash::Configuration::Proxy::Run::MINIMUM_VERSION` in tests** — never hardcode a proxy tag like `"v0.9.2.1"` in an assertion; see `test/commands/proxy_test.rb`.
- **New code that touches the proxy image org** uses `ghcr.io/zoolutions/dash-proxy` (via `Proxy::Run#repository` / `Proxy::Boot#repository_name`), not `basecamp/kamal-proxy`.
- **Loadbalancer-only code** (`Dash::Cli::Proxy#loadbalancer`, `DASH.loadbalancer`, `Configuration::Proxy#load_balancing?`) is fork-owned — keep it isolated behind `load_balancing?` checks so it degrades cleanly when unset, since it auto-activates when the primary role has >1 host.

## Testing (Minitest + Mocha, not RSpec)

```ruby
# Good: ActiveSupport::TestCase, `test "..." do`, assert_equal on argv join
class CommandsProxyTest < ActiveSupport::TestCase
  test "proxy stop" do
    assert_equal "docker container stop kamal-proxy", new_command.stop.join(" ")
  end
end

# Bad: RSpec-style describe/it/expect — this codebase doesn't use RSpec
RSpec.describe Dash::Commands::Proxy do
  it "stops the proxy" do
    expect(subject.stop.join(" ")).to eq("docker container stop kamal-proxy")
  end
end
```

- Mock with `mocha` (`SomeClass.any_instance.stubs(:foo).returns(...)`), not `rspec-mocks`.
- Unit tests live under `test/{cli,commands,configuration}` and must not touch Docker. Run them with:
  ```bash
  bundle exec ruby -Itest -e 'Dir["test/**/*_test.rb"].grep_v(/integration/).each { |f| require File.expand_path(f) }'
  ```
- Integration tests (`test/integration`) run real deploys in Docker and need `ghcr.io/zoolutions/dash-proxy:$MINIMUM_VERSION` published first. Run the full suite with `bin/test`.
- The suite no longer depends on the host's Docker: `test_helper.rb` pins the architecture and stubs the real-build helper, so a local failure is a real failure.

## Code Quality Checklist

Before marking work complete:
- [ ] Code is readable and well-named
- [ ] Methods are small (<30 lines ideal, <50 max)
- [ ] Files are focused (<800 lines)
- [ ] No deep nesting (>4 levels)
- [ ] CLI/Commands/Configuration layers not mixed (see `CLAUDE.md` architecture)
- [ ] Proper error handling — rescue specific SSHKit/Docker errors, not `StandardError`
- [ ] Docker/shell args built via `Dash::Commands::*` + `argumentize`/`optionize`, not inline strings
- [ ] Tests use Minitest + Mocha; proxy version assertions interpolate `MINIMUM_VERSION`
- [ ] `bundle exec rubocop --parallel` passes
- [ ] Releases go through `rake release[X.Y.Z]` (never hand-rolled tags)
