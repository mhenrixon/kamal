# Without a cache mount, an install that misses the layer cache downloads every package
# again. With one, it reuses whatever the last build left behind.
class Dash::Dockerfile::Rules::NoCacheMount < Dash::Dockerfile::Rules::Base
  def findings
    document.instructions.filter_map do |instruction|
      next unless installs?(instruction)
      next if Array(instruction.flags["mount"]).any? { |mount| mount.include?("type=cache") }

      note at(instruction), "#{command_for(instruction)} runs without a cache mount, so a cache miss downloads everything again",
        "add --mount=type=cache,target=#{target_for(instruction)}"
    end
  end

  private
    def installs?(instruction)
      context.dependency_install?(instruction) || context.apt_install?(instruction)
    end

    def command_for(instruction)
      context.install_command(instruction) || "apt-get install"
    end

    def target_for(instruction)
      context.install_cache_target(instruction) || Dash::Dockerfile::Context::APT_INSTALL.last
    end
end
