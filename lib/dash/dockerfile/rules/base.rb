require "active_support/core_ext/module/delegation"

# A rule looks at the analysis context and returns findings. Nothing else: no IO, no
# state, no ordering assumptions about the other rules.
#
# The id is derived from the class name and is a public string — operators put it in
# `report: ignore:`, so renaming a rule class renames a config value.
class Dash::Dockerfile::Rules::Base
  attr_reader :context
  delegate :document, :build, :builder, :context_dir, :dockerignore, to: :context

  class << self
    def id
      @id ||= name.demodulize.underscore.dasherize
    end
  end

  def initialize(context)
    @context = context
  end

  def findings
    []
  end

  private
    def warning(location, message, suggestion = nil)
      finding :warn, location, message, suggestion
    end

    def note(location, message, suggestion = nil)
      finding :info, location, message, suggestion
    end

    def finding(severity, location, message, suggestion)
      Dash::Dockerfile::Finding.new \
        rule: self.class.id, severity: severity, location: location, message: message, suggestion: suggestion
    end

    def at(instruction)
      context.location_for(instruction)
    end
end
