require "test_helper"

class ConfigurationTest < ActiveSupport::TestCase
  setup do
    ENV["RAILS_MASTER_KEY"] = "456"
    ENV["VERSION"] = "missing"

    @deploy = {
      service: "app", image: "dhh/app",
      registry: { "username" => "dhh", "password" => "secret" },
      builder: { "arch" => "amd64" },
      env: { "REDIS_URL" => "redis://x/y" },
      servers: [ "1.1.1.1", "1.1.1.2" ],
      volumes: [ "/local/path:/container/path" ]
    }

    @config = Dash::Configuration.new(@deploy)

    # `healthcheck: false` keeps the readiness warning out of every unrelated test's
    # stderr. The tests that exercise the warning delete the key first.
    @deploy_with_roles = @deploy.dup.merge({
      servers: { "web" => [ "1.1.1.1", "1.1.1.2" ], "workers" => { "hosts" => [ "1.1.1.1", "1.1.1.3" ], "healthcheck" => false } } })

    @config_with_roles = Dash::Configuration.new(@deploy_with_roles)
  end

  teardown do
    ENV.delete("RAILS_MASTER_KEY")
    ENV.delete("VERSION")
  end

  %i[ service image registry ].each do |key|
    test "#{key} config required" do
      assert_raise(Dash::ConfigurationError) do
        Dash::Configuration.new @deploy.tap { |config| config.delete key }
      end
    end
  end

  %w[ username password ].each do |key|
    test "registry #{key} required" do
      assert_raise(Dash::ConfigurationError) do
        Dash::Configuration.new @deploy.tap { |config| config[:registry].delete key }
      end
    end
  end

  test "image uses service name if registry is local" do
    assert_equal "app", Dash::Configuration.new(@deploy.tap {
      _1[:registry] = { "server" => "localhost:5000" }
      _1.delete(:image)
    }).image
  end

  test "image uses image if registry is local" do
    assert_equal "dhh/app", Dash::Configuration.new(@deploy.tap {
      _1[:registry] = { "server" => "localhost:5000" }
    }).image
  end

  test "service name valid" do
    assert_nothing_raised do
      Dash::Configuration.new(@deploy.tap { |config| config[:service] = "hey-app1_primary" })
      Dash::Configuration.new(@deploy.tap { |config| config[:service] = "MyApp" })
    end
  end

  test "service name invalid" do
    assert_raise(Dash::ConfigurationError) do
      Dash::Configuration.new @deploy.tap { |config| config[:service] = "app.com" }
    end
  end

  test "servers required" do
    assert_raise(Dash::ConfigurationError) do
      Dash::Configuration.new @deploy.tap { |config| config.delete(:servers) }
    end
  end

  test "servers not required with accessories" do
    assert_nothing_raised do
      @deploy.delete(:servers)
      @deploy[:accessories] = { "foo" => { "image" => "foo/bar", "host" => "1.1.1.1" } }

      Dash::Configuration.new(@deploy)
    end
  end

  test "roles" do
    assert_equal %w[ web ], @config.roles.collect(&:name)
    assert_equal %w[ web workers ], @config_with_roles.roles.collect(&:name)
  end

  test "role" do
    assert @config.role(:web).name.web?
    assert_equal "workers", @config_with_roles.role(:workers).name
    assert_nil @config.role(:missing)
  end

  test "all hosts" do
    assert_equal [ "1.1.1.1", "1.1.1.2" ], @config.all_hosts
    assert_equal [ "1.1.1.1", "1.1.1.2", "1.1.1.3" ], @config_with_roles.all_hosts
  end

  test "primary host" do
    assert_equal "1.1.1.1", @config.primary_host
    assert_equal "1.1.1.1", @config_with_roles.primary_host
  end

  test "proxy hosts" do
    assert_equal [ "1.1.1.1", "1.1.1.2" ], @config_with_roles.proxy_hosts

    @deploy_with_roles[:servers]["workers"]["proxy"] = true
    config = Dash::Configuration.new(@deploy_with_roles)

    assert_equal [ "1.1.1.1", "1.1.1.2", "1.1.1.3" ], config.proxy_hosts
  end

  test "filtered proxy hosts" do
    assert_equal [ "1.1.1.1", "1.1.1.2" ], @config_with_roles.proxy_hosts

    @deploy_with_roles[:servers]["workers"]["proxy"] = true
    config = Dash::Configuration.new(@deploy_with_roles)

    assert_equal [ "1.1.1.1", "1.1.1.2", "1.1.1.3" ], config.proxy_hosts
  end

  test "version no git repo" do
    ENV.delete("VERSION")

    Dash::Git.expects(:used?).returns(nil)
    error = assert_raises(RuntimeError) { @config.version }
    assert_match /no git repository found/, error.message
  end

  test "version from git committed" do
    ENV.delete("VERSION")

    Dash::Git.expects(:revision).returns("git-version")
    Dash::Git.expects(:uncommitted_changes).returns("")
    assert_equal "git-version", @config.version
  end

  test "version from git uncommitted" do
    ENV.delete("VERSION")

    Dash::Git.expects(:revision).returns("git-version")
    Dash::Git.expects(:uncommitted_changes).returns("M   file\n")
    assert_equal "git-version", @config.version
  end

  test "version from uncommitted context" do
    ENV.delete("VERSION")

    config = Dash::Configuration.new(@deploy.tap { |c| c[:builder]["context"] = "." })

    Dash::Git.expects(:revision).returns("git-version")
    Dash::Git.expects(:uncommitted_changes).returns("M   file\n")
    assert_match /^git-version_uncommitted_[0-9a-f]{16}$/, config.version
  end

  test "version from env" do
    ENV["VERSION"] = "env-version"
    assert_equal "env-version", @config.version
  end

  test "version from arg" do
    @config.version = "arg-version"
    assert_equal "arg-version", @config.version
  end

  test "repository" do
    assert_equal "dhh/app", @config.repository

    config = Dash::Configuration.new(@deploy.tap { |c| c[:registry].merge!({ "server" => "ghcr.io" }) })
    assert_equal "ghcr.io/dhh/app", config.repository
  end

  test "absolute image" do
    assert_equal "dhh/app:missing", @config.absolute_image

    config = Dash::Configuration.new(@deploy.tap { |c| c[:registry].merge!({ "server" => "ghcr.io" }) })
    assert_equal "ghcr.io/dhh/app:missing", config.absolute_image
  end

  test "service with version" do
    assert_equal "app-missing", @config.service_with_version
  end

  test "hosts required for all roles" do
    # Empty server list for implied web role
    assert_raises(Dash::ConfigurationError) do
      Dash::Configuration.new @deploy.merge(servers: [])
    end

    # Empty server list
    assert_raises(Dash::ConfigurationError) do
      Dash::Configuration.new @deploy.merge(servers: { "web" => [] })
    end

    # Missing hosts key
    assert_raises(Dash::ConfigurationError) do
      Dash::Configuration.new @deploy.merge(servers: { "web" => {} })
    end

    # Empty hosts list
    assert_raises(Dash::ConfigurationError) do
      Dash::Configuration.new @deploy.merge(servers: { "web" => { "hosts" => [] } })
    end

    # Nil hosts
    assert_raises(Dash::ConfigurationError) do
      Dash::Configuration.new @deploy.merge(servers: { "web" => { "hosts" => nil } })
    end

    # One role with hosts, one without
    assert_raises(Dash::ConfigurationError) do
      Dash::Configuration.new @deploy.merge(servers: { "web" => %w[ web ], "workers" => { "hosts" => %w[ ] } })
    end
  end

  test "allow_empty_roles" do
    assert_silent do
      Dash::Configuration.new @deploy.merge(servers: { "web" => %w[ web ], "workers" => { "hosts" => %w[ ] } }, allow_empty_roles: true)
    end

    assert_raises(Dash::ConfigurationError) do
      Dash::Configuration.new @deploy.merge(servers: { "web" => %w[], "workers" => { "hosts" => %w[] } }, allow_empty_roles: true)
    end
  end

  test "volume_args" do
    assert_equal [ "--volume", "/local/path:/container/path" ], @config.volume_args
  end

  test "logging args default" do
    assert_equal [ "--log-opt", "max-size=\"10m\"" ], @config.logging_args
  end

  test "logging args with configured options" do
    config = Dash::Configuration.new(@deploy.tap { |c| c.merge!(logging: { "options" => { "max-size" => "100m", "max-file" => 5 } }) })
    assert_equal [ "--log-opt", "max-size=\"100m\"", "--log-opt", "max-file=\"5\"" ], config.logging_args
  end

  test "logging args with configured driver and options" do
    config = Dash::Configuration.new(@deploy.tap { |c| c.merge!(logging: { "driver" => "local", "options" => { "max-size" => "100m", "max-file" => 5 } }) })
    assert_equal [ "--log-driver", "\"local\"", "--log-opt", "max-size=\"100m\"", "--log-opt", "max-file=\"5\"" ], config.logging_args
  end

  test "erb evaluation of yml config" do
    config = Dash::Configuration.create_from config_file: Pathname.new(File.expand_path("fixtures/deploy.erb.yml", __dir__))
    assert_equal "my-user", config.registry.username
  end

  test "destination is loaded into env" do
    dest_config_file = Pathname.new(File.expand_path("fixtures/deploy_for_dest.yml", __dir__))

    config = Dash::Configuration.create_from config_file: dest_config_file, destination: "world"
    assert_equal ENV["KAMAL_DESTINATION"], "world"
  end

  test "destination yml config merge" do
    dest_config_file = Pathname.new(File.expand_path("fixtures/deploy_for_dest.yml", __dir__))

    config = Dash::Configuration.create_from config_file: dest_config_file, destination: "world"
    assert_equal "1.1.1.1", config.all_hosts.first

    config = Dash::Configuration.create_from config_file: dest_config_file, destination: "mars"
    assert_equal "1.1.1.3", config.all_hosts.first
  end

  test "destination yml config file missing" do
    dest_config_file = Pathname.new(File.expand_path("fixtures/deploy_for_dest.yml", __dir__))

    assert_raises(RuntimeError) do
      config = Dash::Configuration.create_from config_file: dest_config_file, destination: "missing"
    end
  end

  test "destination required" do
    dest_config_file = Pathname.new(File.expand_path("fixtures/deploy_for_required_dest.yml", __dir__))

    assert_raises(ArgumentError, "You must specify a destination") do
      config = Dash::Configuration.create_from config_file: dest_config_file
    end

    assert_nothing_raised do
      config = Dash::Configuration.create_from config_file: dest_config_file, destination: "world"
    end
  end

  test "to_h" do
    expected_config = \
      { roles: [ "web" ],
        hosts: [ "1.1.1.1", "1.1.1.2" ],
        primary_host: "1.1.1.1",
        version: "missing",
        repository: "dhh/app",
        absolute_image: "dhh/app:missing",
        service_with_version: "app-missing",
        ssh_options: { user: "root", port: 22, log_level: :fatal, keepalive: true, keepalive_interval: 30, timeout: 30 },
        sshkit: {},
        volume_args: [ "--volume", "/local/path:/container/path" ],
        builder: { "arch" => "amd64" },
        logging: [ "--log-opt", "max-size=\"10m\"" ] }

    assert_equal expected_config, @config.to_h
  end

  test "min version is lower" do
    config = Dash::Configuration.new(@deploy.tap { |c| c.merge!(minimum_version: "0.0.1") })
    assert_equal "0.0.1", config.minimum_version
  end

  test "min version is equal" do
    config = Dash::Configuration.new(@deploy.tap { |c| c.merge!(minimum_version: Dash::VERSION) })
    assert_equal Dash::VERSION, config.minimum_version
  end

  test "min version is higher" do
    assert_raises(Dash::ConfigurationError) do
      Dash::Configuration.new(@deploy.tap { |c| c.merge!(minimum_version: "10000.0.0") })
    end
  end

  test "run directory" do
    config = Dash::Configuration.new(@deploy)
    assert_equal ".dash", config.run_directory
    assert_equal ".kamal", Dash::Configuration::LEGACY_RUN_DIRECTORY
  end

  test "run directory derivatives hang off the current run directory" do
    config = Dash::Configuration.new(@deploy)
    assert_equal ".dash/apps", config.apps_directory
    assert_equal ".dash/apps/app", config.app_directory
    assert_equal ".dash/apps/app/env", config.env_directory
    assert_equal ".dash/apps/app/assets", config.assets_directory
  end

  test "asset path" do
    assert_nil @config.asset_path
    assert_equal "foo", Dash::Configuration.new(@deploy.merge!(asset_path: "foo")).asset_path
  end

  test "primary role" do
    assert_equal "web", @config.primary_role.name

    config = Dash::Configuration.new(@deploy_with_roles.deep_merge({
      servers: { "alternate_web" => { "hosts" => [ "1.1.1.4", "1.1.1.5" ] } },
      primary_role: "alternate_web" }))


    assert_equal "alternate_web", config.primary_role.name
    assert_equal "1.1.1.4", config.primary_host
    assert config.role(:alternate_web).primary?
    assert config.role(:alternate_web).running_proxy?
  end

  test "primary role missing" do
    error = assert_raises(Dash::ConfigurationError) do
      Dash::Configuration.new(@deploy.merge(primary_role: "bar"))
    end
    assert_match /bar isn't defined/, error.message
  end

  test "retain_containers" do
    assert_equal 5, @config.retain_containers
    config = Dash::Configuration.new(@deploy_with_roles.merge(retain_containers: 2))
    assert_equal 2, config.retain_containers

    assert_raises(Dash::ConfigurationError) { Dash::Configuration.new(@deploy_with_roles.merge(retain_containers: 0)) }
  end

  test "extensions" do
    dest_config_file = Pathname.new(File.expand_path("fixtures/deploy_with_extensions.yml", __dir__))

    config = Dash::Configuration.create_from config_file: dest_config_file
    assert_equal config.role(:web_tokyo).running_proxy?, true
    assert_equal config.role(:web_chicago).running_proxy?, true
  end

  [ ".dash", ".kamal" ].each do |project_directory|
    test "traefik hooks in #{project_directory} raise error" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          FileUtils.mkdir_p "#{project_directory}/hooks"
          FileUtils.touch "#{project_directory}/hooks/post-traefik-reboot"
          FileUtils.touch "#{project_directory}/hooks/pre-traefik-reboot"
          exception = assert_raises(Dash::ConfigurationError) do
            Dash::Configuration.new(@deploy)
          end
          assert_equal "Found pre-traefik-reboot, post-traefik-reboot, these should be renamed to (pre|post)-proxy-reboot", exception.message
        end
      end
    end
  end

  test "proxy ssl roles with no host" do
    @deploy_with_roles[:servers]["workers"]["proxy"] = { "ssl" => true }

    exception = assert_raises(Dash::ConfigurationError) do
      Dash::Configuration.new(@deploy_with_roles)
    end

    assert_equal "servers/workers/proxy: Must set a host to enable automatic SSL", exception.message
  end

  test "proxy ssl roles with multiple servers" do
    @deploy_with_roles[:servers]["workers"]["proxy"] = { "ssl" => true, "host" => "foo.example.com" }

    exception = assert_raises(Dash::ConfigurationError) do
      Dash::Configuration.new(@deploy_with_roles)
    end

    assert_equal "SSL is only supported on a single server unless you provide custom certificates or configure a loadbalancer, found 2 servers for role workers", exception.message
  end

  test "two proxy ssl roles with same host" do
    @deploy_with_roles[:servers]["web"] = { "hosts" => [ "1.1.1.1" ], "proxy" => { "ssl" => true, "host" => "foo.example.com" } }
    @deploy_with_roles[:servers]["workers"] = { "hosts" => [ "1.1.1.1" ], "proxy" => { "ssl" => true, "host" => "foo.example.com" } }

    exception = assert_raises(Dash::ConfigurationError) do
      Dash::Configuration.new(@deploy_with_roles)
    end

    assert_equal "Different roles can't share the same host for SSL: foo.example.com", exception.message
  end

  test "two proxy ssl roles with same host in a hosts array" do
    @deploy_with_roles[:servers]["web"] = { "hosts" => [ "1.1.1.1" ], "proxy" => { "ssl" => true, "hosts" => [ "foo.example.com", "bar.example.com" ] } }
    @deploy_with_roles[:servers]["workers"] = { "hosts" => [ "1.1.1.1" ], "proxy" => { "ssl" => true, "hosts" => [ "www.example.com", "foo.example.com" ] } }

    exception = assert_raises(Dash::ConfigurationError) do
      Dash::Configuration.new(@deploy_with_roles)
    end

    assert_equal "Different roles can't share the same host for SSL: foo.example.com", exception.message
  end

  test "hooks_output default is nil" do
    assert_nil @config.hooks_output_for("pre-deploy")
  end

  test "hooks_output global setting" do
    config = Dash::Configuration.new(@deploy.merge(hooks_output: :verbose))
    assert_equal :verbose, config.hooks_output_for("pre-deploy")
    assert_equal :verbose, config.hooks_output_for("post-deploy")
  end

  test "hooks_output per-hook settings" do
    config = Dash::Configuration.new(@deploy.merge(
      hooks_output: { "pre-deploy" => :verbose, "post-deploy" => :quiet }
    ))
    assert_equal :verbose, config.hooks_output_for("pre-deploy")
    assert_equal :quiet, config.hooks_output_for("post-deploy")
  end

  test "hooks_output per-hook returns nil for unconfigured hooks" do
    config = Dash::Configuration.new(@deploy.merge(
      hooks_output: { "pre-deploy" => :verbose }
    ))
    assert_equal :verbose, config.hooks_output_for("pre-deploy")
    assert_nil config.hooks_output_for("post-deploy")
  end

  test "hooks_output invalid raises error" do
    error = assert_raises(Dash::ConfigurationError) do
      Dash::Configuration.new(@deploy.merge(hooks_output: :invalid))
    end
    assert_match /Invalid hooks_output 'invalid'/, error.message
  end

  test "hooks_output invalid per-hook raises error" do
    error = assert_raises(Dash::ConfigurationError) do
      Dash::Configuration.new(@deploy.merge(hooks_output: { "pre-deploy" => :invalid }))
    end
    assert_match /Invalid hooks_output 'invalid' for hook 'pre-deploy'/, error.message
  end

  test "validate_secrets! passes when all referenced secrets resolve" do
    with_test_secrets("secrets" => "DB_PASSWORD=dbpass\nREGISTRY_PASSWORD=regpass\nGITHUB_TOKEN=token") do
      config = Dash::Configuration.new @deploy.merge(
        registry: { "username" => "dhh", "password" => [ "REGISTRY_PASSWORD" ] },
        builder: { "arch" => "amd64", "secrets" => [ "GITHUB_TOKEN" ] },
        env: { "clear" => { "REDIS_URL" => "redis://x/y" }, "secret" => [ "DB_PASSWORD" ] })

      assert_nothing_raised { config.validate_secrets! }
    end
  end

  test "validate_secrets! raises for a missing env secret" do
    with_test_secrets("secrets" => "REGISTRY_PASSWORD=regpass") do
      config = Dash::Configuration.new @deploy.merge(
        env: { "secret" => [ "DB_PASSWORD" ] })

      error = assert_raises(Dash::ConfigurationError) { config.validate_secrets! }
      assert_match /DB_PASSWORD/, error.message
    end
  end

  test "validate_secrets! raises for a missing registry password secret" do
    with_test_secrets("secrets" => "DB_PASSWORD=dbpass") do
      config = Dash::Configuration.new @deploy.merge(
        registry: { "username" => "dhh", "password" => [ "REGISTRY_PASSWORD" ] })

      error = assert_raises(Dash::ConfigurationError) { config.validate_secrets! }
      assert_match /REGISTRY_PASSWORD/, error.message
    end
  end

  test "validate_secrets! raises for a missing builder secret" do
    with_test_secrets("secrets" => "") do
      config = Dash::Configuration.new @deploy.merge(
        builder: { "arch" => "amd64", "secrets" => [ "GITHUB_TOKEN" ] })

      error = assert_raises(Dash::ConfigurationError) { config.validate_secrets! }
      assert_match /GITHUB_TOKEN/, error.message
    end
  end

  test "validate_secrets! raises for a missing custom ssl certificate secret" do
    with_test_secrets("secrets" => "") do
      config = Dash::Configuration.new @deploy.merge(
        servers: [ "1.1.1.1" ],
        proxy: { "host" => "app.example.com", "ssl" => { "certificate_pem" => "CERT_PEM", "private_key_pem" => "KEY_PEM" } })

      error = assert_raises(Dash::ConfigurationError) { config.validate_secrets! }
      assert_match /CERT_PEM/, error.message
    end
  end

  test "validate_secrets! checks accessory secrets only when requested" do
    with_test_secrets("secrets" => "") do
      config = Dash::Configuration.new @deploy.merge(
        accessories: { "mysql" => { "image" => "mysql:8", "host" => "1.1.1.3", "port" => "3306", "env" => { "secret" => [ "MYSQL_ROOT_PASSWORD" ] } } })

      assert_nothing_raised { config.validate_secrets! }

      error = assert_raises(Dash::ConfigurationError) { config.validate_secrets!(include_accessories: true) }
      assert_match /MYSQL_ROOT_PASSWORD/, error.message
    end
  end

  test "warns when the root boot wait has no limit to pace against" do
    warning = stderred { Dash::Configuration.new(@deploy_with_roles.merge(boot: { "wait" => 10 })) }

    assert_match "boot/wait is set to 10 but boot/limit is not", warning
    assert_match "paces one group of hosts against the next", warning
    assert_match "Set `boot/limit`", warning
  end

  test "warns when a role's boot wait has no limit to pace against" do
    @deploy_with_roles[:servers]["workers"]["boot"] = { "wait" => 5 }

    warning = stderred { Dash::Configuration.new(@deploy_with_roles) }

    assert_match "servers/workers/boot/wait is set to 5 but servers/workers/boot/limit is not", warning
  end

  test "does not warn when boot wait is paired with a canary" do
    # A canary creates groups too, so the wait has a gap to fill.
    assert_equal "", stderred { Dash::Configuration.new(@deploy_with_roles.merge(boot: { "canary" => 1, "wait" => 10 })) }
  end

  test "does not warn when boot wait is paired with a limit" do
    assert_equal "", stderred { Dash::Configuration.new(@deploy_with_roles.merge(boot: { "limit" => 2, "wait" => 10 })) }
  end

  test "does not warn when a role pairs its boot wait with a limit" do
    @deploy_with_roles[:servers]["workers"]["boot"] = { "limit" => 1, "wait" => 5 }

    assert_equal "", stderred { Dash::Configuration.new(@deploy_with_roles) }
  end

  test "does not warn about a boot limit with no wait" do
    assert_equal "", stderred { Dash::Configuration.new(@deploy_with_roles.merge(boot: { "limit" => 2 })) }
  end

  # A percentage limit still resolves to a group size, so it paces just as well as an integer.
  test "does not warn when boot wait is paired with a percentage limit" do
    assert_equal "", stderred { Dash::Configuration.new(@deploy_with_roles.merge(boot: { "limit" => "50%", "wait" => 10 })) }
  end

  test "warns about a non-proxied role with no readiness definition" do
    @deploy_with_roles[:servers]["workers"].delete("healthcheck")

    warning = stderred { Dash::Configuration.new(@deploy_with_roles) }

    assert_match "Non-proxied role(s) workers have no healthcheck", warning
    assert_match "accepts the container as ready 7s after it merely starts", warning
    assert_match "opt out explicitly with `healthcheck: false`", warning
    assert_match "will become an error in a future release", warning
  end

  test "warning names every ungated role" do
    @deploy_with_roles[:servers]["workers"].delete("healthcheck")
    @deploy_with_roles[:servers]["tickers"] = { "hosts" => [ "1.1.1.4" ], "cmd" => "bin/tick" }

    warning = stderred { Dash::Configuration.new(@deploy_with_roles) }

    assert_match "Non-proxied role(s) tickers, workers have no healthcheck", warning
  end

  test "does not warn about a role with no hosts" do
    # Ungated on purpose: the silence has to come from the empty-hosts guard.
    @deploy_with_roles[:servers]["workers"].delete("healthcheck")
    @deploy_with_roles[:servers]["workers"]["hosts"] = []

    assert_equal "", stderred { Dash::Configuration.new(@deploy_with_roles.merge(allow_empty_roles: true)) }
  end

  test "does not warn when the role is gated by a healthcheck" do
    @deploy_with_roles[:servers]["workers"]["healthcheck"] = { "port" => 7434 }

    assert_equal "", stderred { Dash::Configuration.new(@deploy_with_roles) }
  end

  test "does not warn when the role opts out with healthcheck false" do
    @deploy_with_roles[:servers]["workers"]["healthcheck"] = false

    assert_equal "", stderred { Dash::Configuration.new(@deploy_with_roles) }
  end

  test "does not warn when the role hand-rolled a health-cmd option" do
    # Ungated on purpose: the silence has to come from the health-cmd option.
    @deploy_with_roles[:servers]["workers"].delete("healthcheck")
    @deploy_with_roles[:servers]["workers"]["options"] = { "health-cmd" => "pgrep -f bin/jobs" }

    assert_equal "", stderred { Dash::Configuration.new(@deploy_with_roles) }
  end

  test "does not warn when every role runs the proxy" do
    assert_equal "", stderred { Dash::Configuration.new(@deploy) }
  end

  test "parallel_roles? follows the global setting when no role paces itself" do
    assert_not Dash::Configuration.new(@deploy_with_roles).parallel_roles?
    assert Dash::Configuration.new(@deploy_with_roles.merge(boot: { "parallel_roles" => true })).parallel_roles?
  end

  test "a role-level boot forces role-first iteration" do
    @deploy_with_roles[:servers]["workers"]["boot"] = { "limit" => 1 }

    assert Dash::Configuration.new(@deploy_with_roles).parallel_roles?
  end

  test "a role-level boot cannot be combined with an explicit parallel_roles false" do
    @deploy_with_roles[:servers]["workers"]["boot"] = { "limit" => 1 }
    @deploy_with_roles[:boot] = { "parallel_roles" => false }

    error = assert_raises(Dash::ConfigurationError) { Dash::Configuration.new(@deploy_with_roles) }

    assert_match "servers/workers/boot", error.message
    assert_match "boot/parallel_roles: false", error.message
  end

  test "create_from exports the destination under both env prefixes" do
    Dash::Configuration.create_from(config_file: Pathname.new(File.expand_path("fixtures/deploy_for_dest.yml", __dir__)), destination: "world")

    assert_equal "world", ENV["DASH_DESTINATION"]
    assert_equal "world", ENV["KAMAL_DESTINATION"]
  ensure
    ENV.delete("DASH_DESTINATION")
    ENV.delete("KAMAL_DESTINATION")
  end

  test "hooks_path and secrets_path default to the .dash project directory" do
    in_project_with(".dash") do
      config = Dash::Configuration.new(@deploy)

      assert_equal ".dash/hooks", config.hooks_path
      assert_equal ".dash/secrets", config.secrets_path
    end
  end

  test "hooks_path and secrets_path fall back to the legacy .kamal project directory" do
    in_project_with(".kamal") do
      config = Dash::Configuration.new(@deploy)

      assert_equal ".kamal/hooks", config.hooks_path
      assert_equal ".kamal/secrets", config.secrets_path
    end
  end

  test "explicit hooks_path and secrets_path win over both project directories" do
    in_project_with(".dash", ".kamal") do
      config = Dash::Configuration.new(@deploy.merge(hooks_path: "config/hooks", secrets_path: "config/secrets"))

      assert_equal "config/hooks", config.hooks_path
      assert_equal "config/secrets", config.secrets_path
    end
  end

  private
    def in_project_with(*directories)
      original_pwd = Dir.pwd

      Dir.mktmpdir do |tmpdir|
        directories.each { |directory| FileUtils.mkdir_p(File.join(tmpdir, directory)) }

        begin
          Dir.chdir(tmpdir)
          yield
        ensure
          Dir.chdir(original_pwd)
        end
      end
    end
end
