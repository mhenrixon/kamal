require "json"

# The saved reports for one destination, newest first.
#
# Everything here is best-effort by design: the directory is the operator's, a report may
# be half-written by a deploy that was killed mid-flush, and a future dash may write a
# schema this one does not know. None of that is worth a word on a deploy, so an
# unreadable file is skipped rather than reported.
class Dash::Report::History
  attr_reader :directory, :destination

  def initialize(directory, destination: nil)
    @directory = directory
    @destination = destination
  end

  def recent(count)
    documents.first(count)
  end

  def any?
    documents.any?
  end

  # Keeps the newest `count` reports of this destination and deletes the rest. Other
  # destinations are left alone: they have their own budget, and a staging deploy must
  # not age out production's history.
  def prune(count)
    entries.drop(count).each do |path, _document|
      File.delete(path)
    rescue SystemCallError
      nil
    end
  end

  private
    def documents
      entries.map(&:last)
    end

    # Sorted by filename rather than by the timestamp inside, because the name is what an
    # operator sorts by too — and a report whose body we could not read is not one we can
    # order by its contents.
    def entries
      @entries ||= Dir.glob(File.join(directory, "*.json")).sort.reverse.filter_map { |path| entry_for(path) }
    end

    def entry_for(path)
      document = JSON.parse(File.read(path), symbolize_names: true)
      return unless document.is_a?(Hash) && document[:schema] == Dash::Report::SCHEMA
      return unless document[:destination] == destination
      return unless well_formed?(document)

      [ path, document ]
    rescue StandardError
      nil
    end

    # Claiming schema 1 is not the same as being one. A hand-edited file that parses but
    # holds the wrong shapes would crash `dash report` when it came to render, which is a
    # long way from where the mistake was made — so it is rejected here, with the
    # unreadable ones, rather than trusted as far as the renderer.
    def well_formed?(document)
      list_of_hashes?(document[:phases]) &&
        (document[:advice].nil? || list_of_hashes?(document[:advice])) &&
        (document[:build].nil? || document[:build].is_a?(Hash))
    end

    def list_of_hashes?(value)
      value.is_a?(Array) && value.all?(Hash)
    end
end
