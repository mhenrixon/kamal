require "active_support/core_ext/object/try"

module Dash::Utils
  extend self

  DOLLAR_SIGN_WITHOUT_SHELL_EXPANSION_REGEX = /\$(?!{[^\}]*\})/

  # Return a list of escaped shell arguments using the same named argument against the passed attributes (hash or array).
  def argumentize(argument, attributes, sensitive: false)
    Array(attributes).flat_map do |key, value|
      if value.present?
        attr = "#{key}=#{escape_shell_value(value)}"
        attr = self.sensitive(attr, redaction: "#{key}=[REDACTED]") if sensitive
        [ argument, attr ]
      elsif value == false
        [ argument, "#{key}=false" ]
      else
        [ argument, key ]
      end
    end
  end

  # Returns a list of shell-dashed option arguments. If the value is true, it's treated like a value-less option.
  # A Sensitive value stays Sensitive: the rendered option keeps the real value
  # for execution and a redacted form for anything kamal prints - same contract
  # as argumentize's `sensitive:` kwarg, but decided per value by the caller.
  def optionize(args, with: nil, escape: true)
    options = if with
      flatten_args(args).collect do |(key, value)|
        if value == true
          "--#{key}"
        else
          rendered = "--#{key}#{with}#{escape ? escape_shell_value(value) : value}"
          value.is_a?(Dash::Utils::Sensitive) ? sensitive(rendered, redaction: "--#{key}#{with}#{value.redaction}") : rendered
        end
      end
    else
      flatten_args(args).collect do |(key, value)|
        rendered = value == true ? nil : escape ? escape_shell_value(value) : value
        rendered = sensitive(rendered, redaction: value.redaction) if value.is_a?(Dash::Utils::Sensitive)
        [ "--#{key}", rendered ]
      end
    end

    options.flatten.compact
  end

  # dash-proxy takes durations as Go duration strings; deploy.yml takes plain
  # seconds. Zero is a real value (it disables the timeout), so only nil drops out.
  #
  # A value that already carries a unit is passed through untouched. Appending
  # "s" to it would not just be redundant, it would change the meaning: "5m"
  # would become "5ms", which Go parses happily as five milliseconds. An
  # operator who writes a Go duration should get the duration they wrote or an
  # error from the proxy, never a silently different one.
  NUMERIC_DURATION = /\A-?\d+(\.\d+)?\z/

  def seconds_duration(value)
    return if value.nil?

    value.to_s.match?(NUMERIC_DURATION) ? "#{value}s" : value.to_s
  end

  # Flattens a one-to-many structure into an array of two-element arrays each containing a key-value pair
  def flatten_args(args)
    args.flat_map { |key, value| value.try(:map) { |entry| [ key, entry ] } || [ [ key, value ] ] }
  end

  # Marks sensitive values for redaction in logs and human-visible output.
  # Pass `redaction:` to change the default `"[REDACTED]"` redaction, e.g.
  # `sensitive "#{arg}=#{secret}", redaction: "#{arg}=xxxx"
  def sensitive(...)
    Dash::Utils::Sensitive.new(...)
  end

  def redacted(value)
    case
    when value.respond_to?(:redaction)
      value.redaction
    when value.respond_to?(:transform_values)
      value.transform_values { |value| redacted value }
    when value.respond_to?(:map)
      value.map { |element| redacted element }
    else
      value
    end
  end

  # Escape a value to make it safe for shell use.
  def escape_shell_value(value)
    value.to_s.scan(/[\x00-\x7F]+|[^\x00-\x7F]+/) \
      .map { |part| part.ascii_only? ? escape_ascii_shell_value(part) : part }
      .join
  end

  def escape_ascii_shell_value(value)
    value.to_s.dump
      .gsub(/`/, '\\\\`')
      .gsub(DOLLAR_SIGN_WITHOUT_SHELL_EXPANSION_REGEX, '\$')
  end

  # Apply a list of host or role filters, including wildcard matches
  def filter_specific_items(filters, items)
    matches = []

    Array(filters).select do |filter|
      matches += Array(items).select do |item|
        # Only allow * for a wildcard
        # items are roles or hosts
        File.fnmatch(filter, item.to_s, File::FNM_EXTGLOB)
      end
    end

    matches.uniq
  end

  def stable_sort!(elements, &block)
    elements.sort_by!.with_index { |element, index| [ block.call(element), index ] }
  end

  def join_commands(commands)
    commands.map(&:strip).join(" ")
  end

  def docker_arch
    arch = `docker info --format '{{.Architecture}}'`.strip
    case arch
    when /aarch64/
      "arm64"
    when /x86_64/
      "amd64"
    else
      arch
    end
  end

  # buildx reports decimal units, so dash does too — an operator comparing a report row
  # with what buildx printed should see the same number.
  def human_bytes(bytes)
    divisor, unit = [ [ 1_000_000_000, "GB" ], [ 1_000_000, "MB" ], [ 1_000, "kB" ] ].find { |size, _| bytes >= size }
    divisor ? format("%.1f%s", bytes.to_f / divisor, unit) : "#{bytes}B"
  end

  def older_version?(version, other_version)
    Gem::Version.new(version.delete_prefix("v")) < Gem::Version.new(other_version.delete_prefix("v"))
  end
end
