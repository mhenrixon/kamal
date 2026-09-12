class Dash::Configuration::Proxy
  include Dash::Configuration::Validation

  DEFAULT_LOG_REQUEST_HEADERS = [ "Cache-Control", "Last-Modified", "User-Agent" ]
  CONTAINER_NAME = "dash-proxy"
  LOADBALANCER_CONTAINER_NAME = "dash-loadbalancer"
  CLIENT_CA_FILENAME = "client-ca.pem"

  # The image label the prune filters key on, set by dash-proxy's publish
  # workflow.
  IMAGE_TITLE = "dash-proxy"
  LOADBALANCER_IMAGE_TITLE = "dash-loadbalancer"

  NETWORK = "dash"
  CONFIG_VOLUME = "dash-proxy-config"
  LOADBALANCER_CONFIG_VOLUME = "dash-loadbalancer-config"

  # Pre-rename names, kept only so the stage-3c migration can find what a host
  # already has: the container to replace, the volume to copy, the network to
  # bridge, and the image label to keep pruning by. Nothing constructs a
  # resource with these — stage 3d deletes them.
  LEGACY_CONTAINER_NAME = "kamal-proxy"
  LEGACY_LOADBALANCER_CONTAINER_NAME = "kamal-loadbalancer"
  LEGACY_HOLDER_CONTAINER_NAME = "kamal-proxy-net"
  LEGACY_NETWORK = "kamal"
  # Written into the run directory once a host is verifiably past the 3c rename, so the
  # bridge costs it nothing but a `test -f` on every deploy after. Deleted in stage 3d.
  LEGACY_RENAME_MARKER = ".legacy-renamed"
  LEGACY_CONFIG_VOLUME = "kamal-proxy-config"
  LEGACY_LOADBALANCER_CONFIG_VOLUME = "kamal-loadbalancer-config"
  LEGACY_IMAGE_TITLE = "kamal-proxy"
  LEGACY_LOADBALANCER_IMAGE_TITLE = "kamal-loadbalancer"

  # What `compress: true` offers. dash-proxy has no "on" state without an
  # explicit list - --compress *is* the list - so the shorthand has to pick.
  # Best ratio first, matching the proxy's own default ordering; the client's
  # Accept-Encoding q-values still outrank this preference.
  DEFAULT_COMPRESSION_ENCODINGS = %w[ zstd br gzip ].freeze

  SUPPORTED_COMPRESSION_ENCODINGS = %w[ gzip br zstd ].freeze

  # dash-proxy maps `brotli` onto the `br` token that travels in Content-Encoding.
  COMPRESSION_ENCODING_ALIASES = { "brotli" => "br" }.freeze

  # The layering contract. When the fork's load balancer fronts the per-host
  # proxies, every deploy option lives at exactly one layer — or at both, on
  # purpose. Nothing is allowed to be undecided: #deploy_options refuses to
  # emit a key that has no disposition here, and test/proxy_layering_test.rb
  # fails the build if a new option is added without one.
  #
  #   :edge    — only where clients connect. Stripped from the per-app deploy,
  #              applied by the load balancer.
  #   :per_app — only next to the app. Applied per-app, stripped from the
  #              load balancer.
  #   :both    — each layer genuinely has its own copy of the concern.
  #
  # Without load balancing the single proxy is every layer at once and the
  # whole surface applies to it.
  DEPLOY_OPTION_DISPOSITIONS = {
    # --- Edge: TLS terminates where the handshake happens, and dash-proxy
    # gates TLSRedirect on TLSEnabled, so the whole family travels together.
    host: :edge,
    tls: :edge,
    "tls-staging": :edge,
    "tls-certificate-path": :edge,
    "tls-private-key-path": :edge,
    "tls-redirect": :edge,
    "tls-domains-source": :edge,
    "tls-domains-interval": :edge,
    "tls-domains-batch-size": :edge,
    "tls-on-demand-url": :edge,
    "tls-client-ca-path": :edge,

    # --- Edge: the load balancer is the only proxy that ever sees the real
    # client address — an allow list on a per-app proxy would refuse every
    # request (its peer is the LB) and one limiter would count the whole
    # fleet as a single client.
    "allow-ip": :edge,
    "deny-ip": :edge,
    "deny-user-agent": :edge,
    "trusted-proxy": :edge,
    "client-ip-header": :edge,
    "rate-limit": :edge,
    "rate-limit-burst": :edge,
    "rate-limit-exempt": :edge,

    # --- Edge: dash-proxy deletes the Authorization header once a service
    # enforces basic auth, so an inner proxy would 401 the credential-less
    # request the load balancer forwards. Credentials belong at the edge only.
    "basic-auth": :edge,

    # --- Edge: both layers used to pin with the same cookie name but separate
    # HMAC keys, so the inner proxy clobbered the edge pin every other request.
    # Only the edge pin can stick.
    "session-affinity": :edge,
    "session-affinity-cookie": :edge,

    # --- Edge: redirectURLIfNeeded consults r.TLS only, so behind the LB a
    # per-app redirect emits http:// Locations to HTTPS clients. The dynamic
    # redirect map answers where clients connect, for the same reason.
    "canonical-host": :edge,
    redirect: :edge,
    "redirects-source": :edge,
    "redirects-interval": :edge,

    # --- Edge: one response cache, at the edge — two layers of cache would
    # double the storage and let the inner cache serve entries the edge
    # already invalidated. The store it writes into is proxy-wide (proxy/run).
    cache: :edge,
    "cache-max-ttl": :edge,
    "cache-max-body": :edge,
    "cache-max-variants": :edge,
    "cache-vary-header": :edge,
    "cache-vary-cookie": :edge,
    "cache-allow-set-cookie": :edge,

    # --- Edge: splitting reads from writes is a fleet-level routing decision;
    # per-app proxies each front a single host and have nothing to split.
    "read-target": :edge,
    "read-target-websockets": :edge,
    "writer-affinity-timeout": :edge,

    # --- Per-app: applied next to the app, exactly once. The LB forwards to
    # the per-host proxies, so running these at both layers would add a header
    # twice or run a rewrite over its own output.
    "set-request-header": :per_app,
    "add-request-header": :per_app,
    "remove-request-header": :per_app,
    "set-response-header": :per_app,
    "add-response-header": :per_app,
    "remove-response-header": :per_app,
    rewrite: :per_app,
    "intercept-errors": :per_app,

    # --- Per-app: sleep stops and starts app containers through the docker
    # socket — the LB has neither the socket nor the containers, and its
    # targets are host addresses, so a sleep flag there fails the deploy.
    "sleep-after": :per_app,
    "wake-timeout": :per_app,
    "sleep-container": :per_app,

    # --- Per-app: compress once, next to the app. Double-running was only
    # safe by accident of the Content-Encoding guard.
    compress: :per_app,
    "compress-content-type": :per_app,
    "compress-min-length": :per_app,

    # --- Both, deliberately: each layer has a real connection pool to its own
    # targets (LB -> per-host proxies, per-host proxy -> app containers), so
    # pool tuning and request deadlines apply to each hop.
    "target-timeout": :both,
    "target-max-conns": :both,
    "target-max-idle-conns": :both,
    "target-idle-conn-timeout": :both,
    "target-dial-timeout": :both,
    "target-disable-keep-alives": :both,
    "target-try-duration": :both,
    "target-try-interval": :both,
    "path-timeout": :both,
    "request-timeout": :both,
    "path-request-timeout": :both,
    "deploy-timeout": :both,
    "drain-timeout": :both,

    # --- Both: each layer health-checks its own targets, buffers its own
    # connections, routes its own paths and writes its own logs.
    "health-check-interval": :both,
    "health-check-timeout": :both,
    "health-check-path": :both,
    "health-check-port": :both,
    "health-check-host": :both,
    "buffer-requests": :both,
    "buffer-responses": :both,
    "buffer-memory": :both,
    "max-request-body": :both,
    "max-response-body": :both,
    "path-prefix": :both,
    "strip-path-prefix": :both,
    "forward-headers": :both,
    "log-request-header": :both,
    "log-response-header": :both,
    "error-pages": :both,
    "exclude-metrics-path": :both
  }.freeze

  # Refusing beats guessing: a deploy option nobody placed would silently land
  # on both layers, which is how session affinity broke in the only topology
  # where it matters.
  def self.disposition(key)
    DEPLOY_OPTION_DISPOSITIONS.fetch(key) do
      raise Dash::ConfigurationError,
        "proxy deploy option --#{key} has no layering disposition - add it to Dash::Configuration::Proxy::DEPLOY_OPTION_DISPOSITIONS"
    end
  end

  delegate :argumentize, :optionize, :seconds_duration, to: Dash::Utils

  attr_reader :config, :proxy_config, :role_name, :run, :secrets

  # `load_balanced: false` marks a registration the fork's load balancer can
  # never front - accessories, whose targets it does not collect. Such a proxy
  # keeps its own host/TLS/basic-auth instead of deferring them to the edge.
  def initialize(config:, proxy_config:, role_name: nil, secrets:, context: "proxy", load_balanced: true)
    @config = config
    @proxy_config = proxy_config
    @proxy_config = {} if @proxy_config.nil?
    @role_name = role_name
    @load_balanced = load_balanced
    @secrets = secrets
    validate! @proxy_config, with: Dash::Configuration::Validator::Proxy, context: context
    @run = Dash::Configuration::Proxy::Run.new(config, run_config: @proxy_config["run"], context: "#{context}/run") if @proxy_config && @proxy_config["run"].present?
  end

  def app_port
    proxy_config.fetch("app_port", 80)
  end

  def ssl?
    proxy_config.fetch("ssl", false)
  end

  def hosts
    proxy_config["hosts"] || proxy_config["host"]&.split(",") || []
  end

  def loadbalancer
    proxy_config["loadbalancer"]
  end

  # Root-level `proxy` setting only; ignored inside role-specific proxy blocks.
  def reboot_on_deploy?
    proxy_config.fetch("reboot_on_deploy", true)
  end

  def load_balancing?
    effective_loadbalancer.present?
  end

  def load_balanced?
    @load_balanced
  end

  def effective_loadbalancer
    return nil unless load_balanced?
    return false if loadbalancer == false
    return primary_role_first_host if loadbalancer == true
    return loadbalancer if loadbalancer.present?
    return primary_role_first_host if auto_load_balanced_primary_role?

    nil
  end

  def loadbalancer_on_proxy_host?
    load_balancing? && config.proxy_hosts.include?(effective_loadbalancer)
  end

  def custom_ssl_certificate?
    ssl = proxy_config["ssl"]
    return false unless ssl.is_a?(Hash)
    ssl["certificate_pem"].present? && ssl["private_key_pem"].present?
  end

  def certificate_pem_content
    ssl = proxy_config["ssl"]
    return nil unless ssl.is_a?(Hash)
    secrets[ssl["certificate_pem"]]
  end

  def private_key_pem_content
    ssl = proxy_config["ssl"]
    return nil unless ssl.is_a?(Hash)
    secrets[ssl["private_key_pem"]]
  end

  def host_tls_cert
    tls_path(config.proxy_boot.tls_directory, "cert.pem")
  end

  def host_tls_key
    tls_path(config.proxy_boot.tls_directory, "key.pem")
  end

  def container_tls_cert
    tls_path(config.proxy_boot.tls_container_directory, "cert.pem")
  end

  def container_tls_key
    tls_path(config.proxy_boot.tls_container_directory, "key.pem") if custom_ssl_certificate?
  end

  # Everything TLS lives in the one `ssl` hash - certificate material,
  # on-demand issuance and the mTLS client CA. One naming family instead of a
  # separate `tls:` block.
  def ssl_config
    proxy_config["ssl"].is_a?(Hash) ? proxy_config["ssl"] : {}
  end

  def on_demand_url
    ssl_config["on_demand_url"]
  end

  # The name of a secret in .dash/secrets holding the CA bundle client
  # certificates must chain to - mirroring ssl.certificate_pem, not a local
  # file path. Kamal uploads the content into the app's TLS directory, which
  # the proxy container already mounts, and hands the proxy the path it sees
  # there.
  def client_ca_pem
    ssl_config["client_ca_pem"]
  end

  def client_ca?
    client_ca_pem.present?
  end

  # Resolved at upload time, not config time, so `dash app logs` and friends
  # work on machines without the secret. A blank secret raises like
  # basic_auth.password_secret - silently deploying without the client CA
  # would turn mTLS off.
  def client_ca_pem_content
    secrets[client_ca_pem].tap do |content|
      if content.blank?
        raise Dash::ConfigurationError, "proxy/ssl: client_ca_pem secret '#{client_ca_pem}' is empty"
      end
    end
  end

  def host_client_ca
    tls_file_path(config.proxy_boot.tls_directory, CLIENT_CA_FILENAME) if client_ca?
  end

  def container_client_ca
    tls_file_path(config.proxy_boot.tls_container_directory, CLIENT_CA_FILENAME) if client_ca?
  end

  def path_prefixes
    proxy_config["path_prefixes"] || proxy_config["path_prefix"]&.split(",") || []
  end

  # Nil when unset: the default lives in dash-proxy, not here.
  def healthcheck_path
    proxy_config.dig("healthcheck", "path")
  end

  def deploy_options
    all_deploy_options.select { |key, _| retained_dispositions.include?(self.class.disposition(key)) }
  end

  # The full option surface before the layering contract is applied — what a
  # single proxy (no load balancer) deploys with. Public so the layering canary
  # can enumerate every key the gem emits.
  def all_deploy_options
    {
      host: hosts,
      tls: ssl? ? true : nil,
      "tls-staging": proxy_config["ssl_staging"] ? true : nil,
      "tls-certificate-path": container_tls_cert,
      "tls-private-key-path": container_tls_key,
      "deploy-timeout": seconds_duration(config.deploy_timeout),
      "drain-timeout": seconds_duration(config.drain_timeout),
      "health-check-interval": seconds_duration(proxy_config.dig("healthcheck", "interval")),
      "health-check-timeout": seconds_duration(proxy_config.dig("healthcheck", "timeout")),
      "health-check-path": healthcheck_path,
      "health-check-port": proxy_config.dig("healthcheck", "port"),
      "health-check-host": proxy_config.dig("healthcheck", "host"),
      "target-timeout": seconds_duration(proxy_config["response_timeout"]),
      "read-target": proxy_config.dig("read_routing", "targets").presence,
      "read-target-websockets": proxy_config.dig("read_routing", "websockets") ? true : nil,
      "writer-affinity-timeout": seconds_duration(proxy_config.dig("read_routing", "writer_affinity_timeout")),
      "path-timeout": path_timeout_args("path_response_timeouts"),
      "request-timeout": seconds_duration(proxy_config["request_timeout"]),
      "path-request-timeout": path_timeout_args("path_request_timeouts"),
      "buffer-requests": proxy_config.fetch("buffering", { "requests": true }).fetch("requests", true),
      "buffer-responses": proxy_config.fetch("buffering", { "responses": true }).fetch("responses", true),
      "buffer-memory": proxy_config.dig("buffering", "memory"),
      "max-request-body": proxy_config.dig("buffering", "max_request_body"),
      "max-response-body": proxy_config.dig("buffering", "max_response_body"),
      "path-prefix": path_prefixes,
      "strip-path-prefix": proxy_config.dig("strip_path_prefix"),
      "forward-headers": proxy_config.dig("forward_headers"),
      "tls-redirect": proxy_config.dig("ssl_redirect"),
      "basic-auth": basic_auth_credential,
      "log-request-header": proxy_config.dig("logging", "request_headers") || DEFAULT_LOG_REQUEST_HEADERS,
      "log-response-header": proxy_config.dig("logging", "response_headers"),
      "error-pages": error_pages,
      # A deploy flag despite reading like metrics configuration: where the
      # metrics are served and who may read them are proxy-wide and live under
      # proxy/run, but which of *this service's* paths are counted is per service.
      "exclude-metrics-path": proxy_config["exclude_metrics_paths"].presence
    }.merge(ssl_domains_options).merge(tls_options).merge(cache_options).merge(compress_options)
      .merge(access_control_options).merge(traffic_options).merge(lifecycle_options)
      .merge(target_options).compact
  end

  def deploy_command_args(target:)
    optionize ({ target: "#{target}:#{app_port}" }).merge(deploy_options), with: "="
  end

  # dash-proxy rollout deploy only accepts the target and the timeouts - the service already
  # exists, so it keeps the host, TLS, buffering and logging options of the live deploy.
  def rollout_deploy_options
    {
      "deploy-timeout": seconds_duration(config.deploy_timeout),
      "drain-timeout": seconds_duration(config.drain_timeout)
    }.compact
  end

  def rollout_deploy_command_args(target:)
    optionize ({ target: "#{target}:#{app_port}" }).merge(rollout_deploy_options), with: "="
  end

  def rollout_set_command_args(percent: nil, list: nil)
    optionize({ percent: percent, list: list }.compact, with: "=")
  end

  def stop_options(drain_timeout: nil, message: nil)
    {
      "drain-timeout": seconds_duration(drain_timeout),
      message: message
    }.compact
  end

  def stop_command_args(**options)
    optionize stop_options(**options), with: "="
  end

  def merge(other)
    self.class.new config: config, proxy_config: other.proxy_config.deep_merge(proxy_config), role_name: role_name, secrets: secrets, load_balanced: load_balanced?
  end

  private
    # Which dispositions this layer keeps. The per-app proxy behind a load
    # balancer sheds the edge concerns; without load balancing there is no
    # other layer to defer to. Dash::Configuration::Loadbalancer overrides
    # this to keep the edge and shed the per-app concerns.
    def retained_dispositions
      load_balancing? ? %i[ per_app both ] : %i[ edge per_app both ]
    end

    def primary_role_first_host
      config.primary_role&.hosts&.first
    end

    # Auto-activation needs a role the load balancer can actually front. The
    # target list is built from roles where `running_proxy?` (see
    # Dash::Cli::Proxy#loadbalancer), so a proxy-less primary role would boot a
    # load balancer with an empty --target. An explicit `loadbalancer:` setting
    # skips this check — the operator asked for it.
    def auto_load_balanced_primary_role?
      primary_role = config.primary_role

      primary_role.present? && primary_role.running_proxy? && Array(primary_role.hosts).size > 1
    end

    # Flags for dash-proxy's dynamic domain source (runtime TLS hostnames).
    # TLS terminates wherever these flags land — :edge in the layering contract.
    def ssl_domains_options
      {
        "tls-domains-source": proxy_config.dig("ssl_domains", "source"),
        "tls-domains-interval": seconds_duration(proxy_config.dig("ssl_domains", "interval")),
        "tls-domains-batch-size": proxy_config.dig("ssl_domains", "batch_size")
      }.compact
    end

    # On-demand issuance and the mTLS client CA only matter where the
    # handshake happens (:edge) - an ask endpoint or a client CA on a proxy
    # that never terminates TLS would do nothing at all.
    def tls_options
      {
        "tls-on-demand-url": on_demand_url,
        "tls-client-ca-path": container_client_ca
      }.compact
    end

    # The connection pool between the proxy and this app's containers, and how
    # hard the proxy tries to place a request on a healthy one.
    #
    # Every value is passed through exactly as written. dash-proxy resolves its
    # own defaults from a zero (target_pool.go), and it has to do that server
    # side because restored state and older RPC clients never see the CLI — so
    # substituting a default here would be both redundant and wrong.
    def target_options
      target = proxy_config["target"] || {}

      {
        "target-max-conns": target["max_conns"],
        "target-max-idle-conns": target["max_idle_conns"],
        "target-idle-conn-timeout": seconds_duration(target["idle_conn_timeout"]),
        "target-dial-timeout": seconds_duration(target["dial_timeout"]),
        "target-disable-keep-alives": target["disable_keep_alives"] ? true : nil,
        "target-try-duration": seconds_duration(target["try_duration"]),
        "target-try-interval": seconds_duration(target["try_interval"])
      }.compact
    end

    # Session affinity and scale-to-zero: which target a client keeps, and
    # whether the targets are running at all. Not one layer: affinity is :edge
    # (an inner pin would clobber the edge pin), sleep is :per_app (only the
    # app hosts have the docker socket and the containers).
    #
    # Sleep needs the container runtime socket, which is a run-level setting -
    # Dash::Configuration#ensure_sleep_has_a_docker_socket refuses the pairing
    # rather than letting the first request after an idle period hang.
    def lifecycle_options
      affinity = proxy_config["session_affinity"] || {}
      sleep_config = proxy_config["sleep"] || {}
      affinity_enabled = affinity["enabled"] ? true : nil

      {
        "session-affinity": affinity_enabled,
        "session-affinity-cookie": (affinity["cookie"] if affinity_enabled),
        "sleep-after": seconds_duration(sleep_config["after"]),
        "wake-timeout": seconds_duration(sleep_config["wake_timeout"]),
        "sleep-container": sleep_config["containers"].presence
      }.compact
    end

    # Header rewriting, redirects, rewrites and error interception. Not one
    # layer: headers/rewrites/error interception are :per_app (the LB would
    # append an `add` header twice and run a rewrite over its own output),
    # while canonical-host and redirect are :edge (they consult r.TLS, so
    # behind the LB they would emit http:// Locations to HTTPS clients).
    def traffic_options
      {
        "set-request-header": header_rules("request", "set"),
        "add-request-header": header_rules("request", "add"),
        "remove-request-header": headers_config.dig("request", "remove").presence,
        "set-response-header": header_rules("response", "set"),
        "add-response-header": header_rules("response", "add"),
        "remove-response-header": headers_config.dig("response", "remove").presence,
        redirect: path_rules("redirects"),
        rewrite: path_rules("rewrites"),
        # The dynamic map is consulted before the static redirect rules above -
        # they compose, the rules running when the map misses.
        "redirects-source": proxy_config.dig("redirects_source", "source"),
        "redirects-interval": seconds_duration(proxy_config.dig("redirects_source", "interval")),
        "canonical-host": proxy_config["canonical_host"],
        "intercept-errors": proxy_config["intercept_errors"].presence
      }.compact
    end

    def headers_config
      proxy_config["headers"] || {}
    end

    # dash-proxy cuts a rule at the first colon, so a value carrying colons of
    # its own arrives intact.
    def header_rules(direction, verb)
      (headers_config.dig(direction, verb) || {}).map { |name, value| "#{name}: #{value}" }.presence
    end

    # '<pattern>=<replacement>', with ';status=<code>' appended for a redirect
    # that asks for one. Cut at the first '=' on the proxy side.
    def path_rules(key)
      Array(proxy_config[key]).map do |rule|
        "#{rule["from"]}=#{rule["to"]}#{";status=#{rule["status"]}" if rule["status"]}"
      end.presence
    end

    # Rate limiting, the IP allow list, and the client-IP identification both of
    # them key on. :edge - the per-host proxy's peer is the load balancer, so an
    # allow list there would refuse every request and one limiter would count
    # the whole fleet as a single client.
    def access_control_options
      client_ip = proxy_config["client_ip"] || {}
      rate_limit = proxy_config["rate_limit"] || {}

      {
        "allow-ip": proxy_config["allow_ips"].presence,
        # Checked before the allow list on the proxy side - an address on both
        # lists is denied. UA patterns run after the IP rules.
        "deny-ip": proxy_config["deny_ips"].presence,
        "deny-user-agent": proxy_config["deny_user_agents"].presence,
        "trusted-proxy": client_ip["trusted_proxies"].presence,
        "client-ip-header": client_ip["header"],
        "rate-limit": rate_limit["requests"],
        "rate-limit-burst": rate_limit["burst"],
        "rate-limit-exempt": rate_limit["exempt"].presence
      }.compact
    end

    # `compress: true` and the block form both land here. --compress is a list of
    # encodings rather than a switch, so "on" always means naming them: a bare
    # --compress would take the next flag on the command line as its value.
    #
    # An explicit `enabled: false` wins over encodings implying "on" - it is
    # the off switch for a block whose tuning the operator wants to keep.
    def compress_options
      compress = proxy_config["compress"]
      settings = compress.is_a?(Hash) ? compress : {}
      return {} if settings["enabled"] == false
      return {} unless compress == true || settings["enabled"] || settings["encodings"].present?

      {
        compress: settings["encodings"].presence || DEFAULT_COMPRESSION_ENCODINGS,
        "compress-content-type": settings["content_types"].presence,
        "compress-min-length": settings["min_length"]
      }.compact
    end

    # The cache policy, which is per service - the store it writes into is
    # proxy-wide and lives in proxy/run/cache. Only --cache is derived from a
    # truthy key; every other default stays in dash-proxy, so an unset key emits
    # nothing rather than restating a default the gem would then have to track.
    def cache_options
      cache = proxy_config["cache"] || {}

      {
        cache: cache["enabled"] ? true : nil,
        "cache-max-ttl": seconds_duration(cache["max_ttl"]),
        "cache-max-body": cache["max_body"],
        "cache-max-variants": cache["max_variants"],
        "cache-vary-header": cache["vary_headers"].presence,
        "cache-vary-cookie": cache["vary_cookies"].presence,
        "cache-allow-set-cookie": cache["allow_set_cookie"] ? true : nil
      }.compact
    end

    def tls_path(directory, filename)
      tls_file_path(directory, filename) if custom_ssl_certificate?
    end

    # The path construction on its own: a client CA bundle lives beside the
    # server certificate but has nothing to do with whether one was configured.
    def tls_file_path(directory, filename)
      File.join([ directory, role_name, filename ].compact)
    end

    # dash-proxy takes the credential as <username>:<password> and cuts at the
    # first colon, so a password may contain colons but a username may not (the
    # validator enforces that). The password is read from .dash/secrets when
    # password_secret names it, so it need not live in deploy.yml.
    def basic_auth_credential
      basic_auth = proxy_config["basic_auth"]
      return nil unless basic_auth.is_a?(Hash)

      password =
        if (secret_name = basic_auth["password_secret"]).present?
          secrets[secret_name]
        else
          basic_auth["password"]
        end

      # The validator guarantees a password was configured, so a blank one here
      # means the named secret resolved empty. Fail rather than drop the flag —
      # silently deploying an unprotected service is the worse outcome.
      if password.blank?
        raise Dash::ConfigurationError, "proxy/basic_auth: password_secret '#{secret_name}' is empty"
      end

      # Sensitive, so SSHKit redacts the credential wherever kamal prints the
      # deploy command - at :info verbosity it used to land in plain text
      # (registry-login precedent; Utils.optionize passes the marking through).
      Dash::Utils.sensitive("#{basic_auth["username"]}:#{password}")
    end

    # Serves both --path-timeout and --path-request-timeout, which dash-proxy
    # reads with one parser. A duration may be a Go string ("5m") or plain
    # seconds; 0 is a value, meaning no limit for that prefix.
    def path_timeout_args(key)
      if (timeouts = proxy_config[key]).present?
        timeouts.map do |prefix, duration|
          duration = seconds_duration(duration) if duration.is_a?(Numeric)
          "#{prefix}=#{duration}"
        end
      end
    end

    def error_pages
      File.join config.proxy_boot.error_pages_container_directory, config.version if config.error_pages_path
    end
end
