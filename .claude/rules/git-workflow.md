# Git Workflow Rules

Post-clean-break (2026-08, zoolutions/dash#115): there is no upstream, no mirror branch, no fork tag grammar. See `.claude/rules/upstream-sync.md` for the historical note.

## Branch Model

| Branch | Role | Rule |
|---|---|---|
| `main` | The branch — default, protected, releases cut from here | Lands via PR; never force-push |
| `feat/*`, `fix/*`, ... | Feature branches | Root off `main`, PR back into `main` |

**NEVER** rebase a published branch — history is shared, merge forward instead.

## Commit Messages

Conventional commits:
- `feat:` — new feature
- `fix:` — bug fix
- `refactor:` — code refactoring
- `perf:` — performance improvement
- `docs:` — documentation only
- `test:` — adding/updating tests
- `chore:` — maintenance tasks
- `ci:` — CI/CD changes

Format:
```
feat(scope): brief description

Longer explanation if needed. Focus on WHY, not WHAT.

Refs #123
```

## Branch Naming

- `feat/description` — new features (e.g. `feat/loadbalancing`)
- `fix/description` — bug fixes
- `refactor/description` — refactoring
- `ci/description` — CI changes
- `chore/description` — maintenance

## PR Workflow

1. Branch off `main`
2. Make focused, atomic commits
3. Run the pre-commit checklist before every push
4. Open the PR against `main` (`--repo zoolutions/dash`)
5. Request review
6. Merge `main` → your feature branch whenever `main` moves, then merge the branch back — never rebase

## PR and Issue Bodies

Write PR/issue bodies in plain Markdown. **Do not escape backticks** with `\`` — GitHub renders `\`` literally as a backslash followed by a backtick, producing `` \`Dash::Commander\` `` instead of the monospace `Dash::Commander` the reader expects.

The usual cause is writing the body inside a bash heredoc (`gh pr create --body "$(cat <<'EOF' ... EOF)"`) and reflexively escaping every backtick out of shell-quoting muscle memory. With `<<'EOF'` (single-quoted delimiter) the shell does NOT interpret anything inside the heredoc — backticks, dollars, and backslashes all pass through verbatim. Write them exactly as you want them rendered. If you find yourself typing `\`` inside a PR body, stop and remove the backslash.

For long bodies or many code fences, prefer `--body-file <tmpfile>` — it skips shell interpretation entirely.

## Pre-Commit Checklist

Run before EVERY commit:
```bash
bundle exec rubocop --parallel        # Style
bundle exec ruby -Itest -e 'Dir["test/**/*_test.rb"].grep_v(/integration/).each { |f| require File.expand_path(f) }'  # Unit tests (no Docker)
```

Before pushing `main`-bound work or opening a PR, run the full suite (needs Docker + the proxy image published at `MINIMUM_VERSION`):
```bash
bin/test
```

The suite is host-independent: `test_helper.rb` pins the Docker architecture and stubs the one helper that shelled out to a real build, so a local failure is a real failure.

## Tags & Releases

| What | Grammar | Example | How |
|---|---|---|---|
| Gem (this repo) | `v<semver>` | `v3.2.0` | `bin/release` (wraps `rake release[3.2.0]`) |
| Proxy image (dash-proxy) | `v<base>.<n>` or plain `v<semver>` | `v1.0.0.6` | `script/release-dash` in ../kamal-proxy |

- **NEVER** `-suffix` versions (e.g. `v1.0.0-rc1`) — `Gem::Version` parses `-` as a prerelease, which sorts OLDER than the base and hard-fails `dash proxy boot`'s minimum-version check
- **NEVER** `git push --tags` — push single tags; `rake release` handles the gem tag via `gh release create`
- Historical `dash-v*` gem tags and the fork-era grammar are frozen history — don't create new ones

## Release Ordering — Hard Constraint

**Proxy image before gem, always.** `Dash::Configuration::Proxy::Run::MINIMUM_VERSION` must name a tag already published at `ghcr.io/zoolutions/dash-proxy` before the gem releases — integration tests and `dash proxy boot` pull it. `rake release` enforces this with a pullability gate.

```bash
# 1. ../kamal-proxy, on main (only when MINIMUM_VERSION moves or proxy features changed)
script/release-dash v1.0.0.6

# 2. this repo, on main — confirm MINIMUM_VERSION matches, then:
bin/test
bin/release minor       # preview + confirm, then rake release[3.2.0]: bump + commit + push + GitHub release; CI trusted-publishes to RubyGems
```

## Rules

- **NEVER** push directly to `main` — everything lands via PR (admin bypass is for migrations, not routine)
- **NEVER** force push to `main`
- **NEVER** root a feature branch off anything but `main`
- **ALWAYS** run rubocop + unit tests before pushing; run `bin/test` before merging into `main`
- **ALWAYS** write meaningful commit messages — explain WHY
- Keep commits small and focused, one logical change per commit
