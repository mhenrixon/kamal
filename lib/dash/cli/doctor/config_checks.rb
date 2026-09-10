# Checks that only read the configuration — no SSH, no network. They report problems
# that are visible in deploy.yml alone, so they still run when every host is unreachable.
class Dash::Cli::Doctor::ConfigChecks
  def run
    readiness_results + dockerfile_results
  end

  private
    def result(check, target, status, detail)
      Dash::Cli::Doctor::Result.new(check, target, status, detail)
    end

    def readiness_results
      DASH.roles.map { |role| readiness_check(role) }
    end

    def readiness_check(role)
      if role.readiness_source != :none
        result :readiness, role.name, :ok, role.readiness_description
      elsif role.readiness_gated?
        # readiness_gated? with no source left is `healthcheck: false` — the gap is deliberate.
        result :readiness, role.name, :ok, "healthcheck: false — accepted #{role.readiness_delay}s after the container starts"
      else
        result :readiness, role.name, :warn, "no healthcheck — the old container stops #{role.readiness_delay}s after the new one starts; " \
          "add a `healthcheck:` block, or opt out with `healthcheck: false`"
      end
    end

    # The static half of the deploy report's advice: the same rules, without a build to
    # measure against. `advice: false` is not consulted — it silences the block printed
    # next to a deploy, and this check is one the operator asked for by name.
    def dockerfile_results
      dockerfile = DASH.config.builder.dockerfile
      path = File.expand_path(dockerfile)

      unless File.exist?(path)
        return [ result(:dockerfile, dockerfile, :fail, "not found — `dash build push` fails with Missing #{dockerfile}") ]
      end

      findings = analyzer(dockerfile, path).findings
      return [ result(:dockerfile, dockerfile, :ok, "no findings") ] if findings.empty?

      findings.map { |finding| finding_result(finding) }
    rescue StandardError => e
      [ result(:dockerfile, dockerfile, :warn, "could not be analysed (#{e.class}: #{e.message})") ]
    end

    def analyzer(dockerfile, path)
      Dash::Dockerfile::Analyzer.new \
        document: Dash::Dockerfile::Parser.parse(File.read(path)),
        path: dockerfile,
        context_dir: File.expand_path(DASH.config.builder.context),
        builder: DASH.config.builder,
        ignore: DASH.config.report.ignore,
        hadolint: DASH.config.report.hadolint?
    end

    # An informational finding is not a reason to hold up a deploy, so it reports as ok
    # with its message intact — visible, but never the difference between ready and not.
    def finding_result(finding)
      result :dockerfile, finding.location, (finding.warn? ? :warn : :ok), "#{finding.message} [#{finding.rule}]"
    end
end
