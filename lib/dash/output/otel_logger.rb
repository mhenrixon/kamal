class Dash::Output::OtelLogger < Dash::Output::BaseLogger
  def self.build(settings:, config:)
    raise ArgumentError, "OTel endpoint is required" unless settings["endpoint"]
    new(
      endpoint: settings["endpoint"],
      tags: Dash::Tags.from_config(config).except(:service_version, :recorded_at),
      service: config.service
    )
  end

  def initialize(endpoint:, tags:, service: nil)
    @endpoint = endpoint
    @shipper = Dash::OtelShipper.new(endpoint: endpoint, tags: tags)
    @service = service
    super()
  end

  def <<(message)
    host = Thread.current[:kamal_host]
    iostream = Thread.current[:kamal_iostream]
    severity = Thread.current[:kamal_severity]
    @shipper.append(message, host: host, iostream: iostream, severity: severity)
  end

  DEPLOY_COMMANDS = %w[ deploy redeploy rollback setup ].freeze

  private
    def on_start(payload)
      @shipper.event("kamal.start",
        "kamal.command": full_command(payload),
        **deployment_attrs(payload))
    end

    def on_finish(payload, runtime)
      if payload[:exception]
        error_class, error_message = payload[:exception]
        @shipper.event("kamal.failed", severity: :error,
          "kamal.command": full_command(payload), "kamal.runtime": runtime,
          "exception.type": error_class, "exception.message": error_message,
          **deployment_attrs(payload, status: "failed"))
      else
        @shipper.event("kamal.complete",
          "kamal.command": full_command(payload), "kamal.runtime": runtime,
          **deployment_attrs(payload, status: "succeeded"))
      end
      ship_report(payload)
      puts "Logs sent to #{@endpoint}"
    end

    # The same numbers the table printed, as events a backend can chart across deploys.
    # Shipping them must never be the thing that fails a deploy that already succeeded,
    # so anything that goes wrong here costs one line on stderr.
    def ship_report(payload)
      report = payload[:report] or return
      attrs = deployment_attrs(payload)

      report.timings.to_h.each { |phase| @shipper.event("dash.phase", **phase_attrs(phase), **attrs) }
      ship_build(report.build, attrs) if report.build&.any?
      report.advice.each { |finding| @shipper.event("dash.advice", **advice_attrs(finding), **attrs) }
    rescue StandardError => e
      $stderr.puts "OTel report events failed: #{e.class}: #{e.message}"
      $stderr.puts e.backtrace.join("\n") if ENV["VERBOSE"]
    end

    def ship_build(build, attrs)
      @shipper.event("dash.build", **build_attrs(build), **attrs)
      build.dockerfile_steps.each { |step| @shipper.event("dash.build.step", **step_attrs(step), **attrs) }
    end

    def phase_attrs(phase)
      {
        "dash.phase.name": phase[:name], "dash.phase.depth": phase[:depth], "dash.phase.seconds": phase[:seconds],
        "dash.phase.detail": phase[:detail], "dash.phase.commands": phase[:commands],
        "dash.phase.command_seconds": phase[:command_seconds], "dash.phase.connect_seconds": phase[:connect_seconds]
      }.compact
    end

    def build_attrs(build)
      {
        "dash.build.context_bytes": build.context_bytes, "dash.build.context_seconds": build.context_seconds,
        "dash.build.cached_steps": build.cached_steps.size, "dash.build.total_steps": build.dockerfile_steps.size,
        "dash.build.export_seconds": build.export_seconds, "dash.build.cache_export_seconds": build.cache_export_seconds,
        "dash.build.push_seconds": build.push_seconds
      }.compact
    end

    def step_attrs(step)
      {
        "dash.build.stage": step.stage, "dash.build.ordinal": step.ordinal, "dash.build.instruction": step.instruction,
        "dash.build.seconds": step.seconds, "dash.build.cached": step.cached
      }.compact
    end

    def advice_attrs(finding)
      {
        "dash.advice.rule": finding.rule, "dash.advice.severity": finding.severity.to_s,
        "dash.advice.location": finding.location, "dash.advice.message": finding.message
      }.compact
    end

    def on_close
      @shipper.shutdown
    end

    def full_command(payload)
      [ payload[:command], payload[:subcommand] ].compact.join(" ")
    end

    def deploy?(payload)
      DEPLOY_COMMANDS.include?(payload[:command])
    end

    def deployment_attrs(payload, status: nil)
      if deploy?(payload)
        attrs = { "deployment.id": @shipper.run_id, "deployment.name": "#{full_command(payload)} #{@service}" }
        attrs[:"deployment.status"] = status if status
        attrs
      else
        {}
      end
    end
end
