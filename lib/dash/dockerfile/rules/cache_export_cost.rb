# Measured only: mode=max exports every intermediate layer to the cache. On a persistent
# builder that is often pure overhead — but only the numbers from this build can say so.
class Dash::Dockerfile::Rules::CacheExportCost < Dash::Dockerfile::Rules::Base
  SHARE = 0.2
  SUGGESTION = "try mode=min under builder: cache: options:"

  def findings
    return [] unless build && mode_max?

    exported, total = build.cache_export_seconds, build.total_step_seconds
    return [] if total.zero? || exported <= total * SHARE

    [ note("builder.cache", format("exporting the build cache took %.1fs of %.1fs with mode=max", exported, total), SUGGESTION) ]
  end

  private
    def mode_max?
      builder&.cache_to.to_s.include?("mode=max")
    end
end
