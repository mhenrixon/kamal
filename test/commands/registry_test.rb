require "test_helper"

class CommandsRegistryTest < ActiveSupport::TestCase
  setup do
    @config = {
      service: "app",
      image: "dhh/app",
      registry: {
        "username" => "dhh",
        "password" => "secret",
        "server" => "hub.docker.com"
      },
      builder: { "arch" => "amd64" },
      servers: [ "1.1.1.1" ],
      accessories: {
        "db" => {
          "image" => "mysql:8.0",
          "hosts" => [ "1.1.1.1" ],
          "registry" => {
            "username" => "user",
            "password" => "pw",
            "server" => "other.hub.docker.com"
          }
        }
      }
    }
  end

  test "registry login" do
    assert_equal \
      "docker login hub.docker.com -u \"dhh\" -p \"secret\"",
      registry.login.join(" ")
  end

  test "given registry login" do
    assert_equal \
      "docker login other.hub.docker.com -u \"user\" -p \"pw\"",
      registry.login(registry_config: accessory_registry_config).join(" ")
  end

  test "registry login with ENV password" do
    with_test_secrets("secrets" => "KAMAL_REGISTRY_PASSWORD=more-secret\nKAMAL_MYSQL_REGISTRY_PASSWORD=secret-pw") do
      @config[:registry]["password"] = [ "KAMAL_REGISTRY_PASSWORD" ]
      @config[:accessories]["db"]["registry"]["password"] = [ "KAMAL_MYSQL_REGISTRY_PASSWORD" ]

      assert_equal \
        "docker login hub.docker.com -u \"dhh\" -p \"more-secret\"",
        registry.login.join(" ")

      assert_equal \
        "docker login other.hub.docker.com -u \"user\" -p \"secret-pw\"",
        registry.login(registry_config: accessory_registry_config).join(" ")
    end
  end

  test "registry login escape password" do
    with_test_secrets("secrets" => "KAMAL_REGISTRY_PASSWORD=more-secret'\"") do
      @config[:registry]["password"] = [ "KAMAL_REGISTRY_PASSWORD" ]

      assert_equal \
        "docker login hub.docker.com -u \"dhh\" -p \"more-secret'\\\"\"",
        registry.login.join(" ")
    end
  end

  test "registry login with ENV username" do
    with_test_secrets("secrets" => "KAMAL_REGISTRY_USERNAME=also-secret") do
      @config[:registry]["username"] = [ "KAMAL_REGISTRY_USERNAME" ]

      assert_equal \
        "docker login hub.docker.com -u \"also-secret\" -p \"secret\"",
        registry.login.join(" ")
    end
  end

  # The login's own stdout is discarded so a capture folded in behind it comes back with
  # the following command's answer alone.
  test "registry login then command" do
    assert_equal \
      "docker login hub.docker.com -u \"dhh\" -p \"secret\" > /dev/null && docker info --format '{{index .RegistryConfig.Mirrors 0}}'",
      registry.login_then([ :docker, :info, "--format '{{index .RegistryConfig.Mirrors 0}}'" ]).join(" ")
  end

  test "registry login then command keeps the credentials sensitive" do
    command = registry.login_then([ :docker, :info ])

    assert_equal [ "\"dhh\"", "\"secret\"" ], command.grep(Dash::Utils::Sensitive).map(&:unredacted)
  end

  test "registry login then command with a local registry issues the command alone" do
    @config[:registry] = { "server" => "localhost:5000" }

    assert_equal "docker info", registry.login_then([ :docker, :info ]).join(" ")
  end

  test "registry logout" do
    assert_equal \
      "docker logout hub.docker.com",
      registry.logout.join(" ")
  end

  test "given registry logout" do
    assert_equal \
      "docker logout other.hub.docker.com",
      registry.logout(registry_config: accessory_registry_config).join(" ")
  end

  test "registry setup" do
    @config[:registry] = { "server" => "localhost:5000" }
    assert_equal "docker start dash-docker-registry || docker run --detach -p 127.0.0.1:5000:5000 --name dash-docker-registry registry:3", registry.setup.join(" ")
  end

  test "registry remove tears down the legacy container alongside the current one" do
    assert_equal "docker stop dash-docker-registry && docker rm dash-docker-registry ; docker stop kamal-docker-registry && docker rm kamal-docker-registry", registry.remove.join(" ")
  end

  private
    def registry
      Dash::Commands::Registry.new main_config
    end

    def main_config
      Dash::Configuration.new(@config)
    end

    def accessory_registry_config
      main_config.accessory("db").registry
    end
end
