module Dash
  class ConfigurationError < StandardError; end

  # Stamped before the first require so the Startup row in the deploy report covers what
  # it actually costs to get here: gem load, Zeitwerk, and everything bin/dash pulls in.
  PROCESS_STARTED_AT = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

require "active_support"
require "zeitwerk"
require "yaml"
require "tmpdir"
require "pathname"
require "uri"
# Proxy::Run.digest reaches for Digest::SHA256 from inside `on(DASH.proxy_hosts)`,
# so the first reference happens in several SSHKit threads at once. Digest defines
# SHA256 lazily — `Digest.const_missing(:SHA256)` runs `require "digest/sha2"`, and
# that path is not mutex-guarded — so the threads race it and one loses with
# "Digest::Base cannot be directly inherited in Ruby", failing `dash proxy boot`
# on a random host.
#
# Requiring "digest" alone does NOT fix this: it defines the module but leaves
# SHA256 to const_missing. Pull in the implementation itself, before any threads
# exist to race it.
require "digest/sha2"

loader = Zeitwerk::Loader.for_gem
loader.ignore(File.join(__dir__, "dash", "sshkit_with_ext.rb"))
loader.setup
loader.eager_load_namespace(Dash::Cli) # We need all commands loaded.
