# Just enough .dockerignore to answer "does this file ship in the build context?".
#
# Not a reimplementation of BuildKit's matcher: negations are skipped rather than
# applied, so a path this says is covered might still ship. That direction is the safe
# one — it costs a piece of advice, never a false accusation.
class Dash::Dockerfile::Dockerignore
  FILENAME = ".dockerignore"

  attr_reader :patterns

  def self.in(directory)
    path = ::File.join(directory.to_s, FILENAME)
    new(::File.read(path).lines) if ::File.file?(path)
  end

  def initialize(lines)
    @patterns = lines
      .map(&:strip)
      .reject { |line| line.empty? || line.start_with?("#", "!") }
      .map { |line| line.delete_prefix("**/").delete_prefix("./").delete_prefix("/").delete_suffix("/") }
      .reject(&:empty?)
  end

  def covers?(path)
    patterns.any? do |pattern|
      ::File.fnmatch?(pattern, path, ::File::FNM_DOTMATCH) || path.start_with?("#{pattern}/")
    end
  end
end
