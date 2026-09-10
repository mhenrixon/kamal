# frozen_string_literal: true

# In-memory registry of the reference docs. One line per page — slug and view
# derive from the title (both overridable), and the sidebar nav derives from this
# registry with zero extra code (see config/initializers/docs_kit.rb's
# `nav_registries`). It also feeds the AI surfaces (/llms.txt, /llms-full.txt,
# search, MCP): an unwritten page (whose view class doesn't resolve yet) is
# silently skipped everywhere, so the whole list can be declared up front as a
# burn-down of pages to author.
#
# Add a page with `rails g docs_kit:page "Title" --group=…`, which appends the
# `page` line here and writes the class under app/views/docs/pages/. Uses
# DocsKit::Registry for the shared all/from_slug/grouped/nav_items API.
#
# The Configuration group is GENERATED: one page per commented-YAML doc in
# ../lib/dash/configuration/docs (the same files `dash docs` prints), rendered
# through ConfigDoc + Views::Docs::Pages::ConfigPage. The drift spec
# (spec/config_docs_spec.rb) fails when a doc YAML has no page here or a
# ConfigPage here has no YAML. Hand-written pages may sit in the group too
# (Secrets adapters) — they are not ConfigPages and the spec skips them.
class Doc
  extend DocsKit::Registry
  path_prefix    "/docs"
  view_namespace "Views::Docs::Pages"

  # Getting started
  page "Overview",     group: "Getting started"
  page "Installation", group: "Getting started"
  page "Quick start",  group: "Getting started", slug: "quick-start", view: "QuickStart"

  # Migrate
  page "From kamal", group: "Migrate", slug: "from-kamal", view: "FromKamal"

  # Deploying — narrative guides for the deploy path
  page "Worker roles",   group: "Deploying", slug: "worker-roles", view: "WorkerRoles"
  page "Hooks",          group: "Deploying"
  page "Canary rollout", group: "Deploying", slug: "rollout", view: "CanaryRollout"
  page "Reading the deploy report", group: "Deploying", slug: "deploy-report", view: "DeployReport"

  # Proxy — the dash-only features upstream kamal does not have
  page "Load balancing",           group: "Proxy", slug: "load-balancing", view: "LoadBalancing"
  page "SAN batching & wildcards", group: "Proxy", slug: "certificates", view: "Certificates"
  page "Response caching",         group: "Proxy", slug: "caching", view: "Caching"
  page "Traffic shaping",          group: "Proxy", slug: "traffic-shaping", view: "TrafficShaping"

  # Configuration — generated from lib/dash/configuration/docs/*.yml
  page "deploy.yml",       group: "Configuration", slug: "configuration", view: "Config::Configuration"
  page "Servers",          group: "Configuration", slug: "servers", view: "Config::Servers"
  page "Roles",            group: "Configuration", slug: "role", view: "Config::Role"
  page "Proxy",            group: "Configuration", slug: "proxy", view: "Config::Proxy"
  page "Environment",      group: "Configuration", slug: "env", view: "Config::Env"
  page "Secrets adapters", group: "Configuration", slug: "secrets", view: "SecretsAdapters" # hand-written, not YAML-generated
  page "Builder",          group: "Configuration", slug: "builder", view: "Config::Builder"
  page "Registry",         group: "Configuration", slug: "registry", view: "Config::Registry"
  page "Accessories",      group: "Configuration", slug: "accessory", view: "Config::Accessory"
  page "Aliases",          group: "Configuration", slug: "alias", view: "Config::Alias"
  page "Booting",          group: "Configuration", slug: "boot", view: "Config::Boot"
  page "SSH",              group: "Configuration", slug: "ssh", view: "Config::Ssh"
  page "SSHKit",           group: "Configuration", slug: "sshkit", view: "Config::Sshkit"
  page "Logging",          group: "Configuration", slug: "logging", view: "Config::Logging"
  page "Output",           group: "Configuration", slug: "output", view: "Config::Output"
  page "Deploy report",    group: "Configuration", slug: "report", view: "Config::Report"

  # Reference
  page "Commands", group: "Reference"
end
