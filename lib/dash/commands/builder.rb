require "active_support/core_ext/string/filters"

class Dash::Commands::Builder < Dash::Commands::Base
  delegate \
    :create, :remove, :dev, :push, :clean, :pull, :clean_then_pull, :info, :inspect_builder,
    :validate_image, :first_mirror, :login_to_registry_locally?, :push_env,
    to: :target

  delegate \
    :local?, :remote?, :pack?, :cloud?,
    to: "config.builder"

  include Clone

  def name
    target.class.to_s.remove("Dash::Commands::Builder::").underscore.inquiry
  end

  def target
    if remote?
      if local?
        hybrid
      else
        remote
      end
    elsif pack?
      pack
    elsif cloud?
      cloud
    else
      local
    end
  end

  def remote
    @remote ||= Dash::Commands::Builder::Remote.new(config)
  end

  def local
    @local ||= Dash::Commands::Builder::Local.new(config)
  end

  def hybrid
    @hybrid ||= Dash::Commands::Builder::Hybrid.new(config)
  end

  def pack
    @pack ||= Dash::Commands::Builder::Pack.new(config)
  end

  def cloud
    @cloud ||= Dash::Commands::Builder::Cloud.new(config)
  end
end
