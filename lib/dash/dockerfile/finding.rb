# One piece of advice about the Dockerfile or the build context.
#
# `rule` is a stable public string an operator can put in `report: ignore:`, so renaming
# one is a breaking change to their deploy.yml. `location` is whatever they should open:
# a Dockerfile line, `.dockerignore`, `build context`, or a deploy.yml key.
Dash::Dockerfile::Finding = Struct.new(:rule, :severity, :location, :message, :suggestion, keyword_init: true) do
  def warn?
    severity == :warn
  end

  def to_h
    { rule: rule, severity: severity.to_s, location: location, message: message, suggestion: suggestion }
  end
end
