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
    # order by its contents. Newest first.
    def entries
      @entries ||= Dir.glob(File.join(directory, "*.json")).sort_by { |path| order_key(path) }.reverse.filter_map { |path| entry_for(path) }
    end

    # Two runs in the same second are `X.json` and `X-2.json`, and byte for byte the
    # unsuffixed one sorts last — which would make the older run the newest. The suffix
    # is the run order; the command a name ends in is never a number, so a trailing
    # `-N` is only ever ours.
    def order_key(path)
      name = File.basename(path, ".json")
      base, suffix = name.match(/\A(.*)-(\d+)\z/)&.captures

      base ? [ base, suffix.to_i ] : [ name, 1 ]
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
    # holds the wrong shapes would crash `dash report` somewhere far from the mistake, or
    # — worse — render as an empty table. The top-level fields the writer always sets are
    # checked by shape; then the test that matters for everything nested: render it.
    # Anything that cannot be is skipped with the unreadable files, the raise landing in
    # #entry_for's rescue.
    def well_formed?(document)
      return false unless list_of_hashes?(document[:phases])
      return false unless optional?(document[:advice]) { |advice| list_of_hashes?(advice) }
      return false unless optional?(document[:build]) { |build| build.is_a?(Hash) }
      return false unless optional?(document[:error]) { |error| error.is_a?(Hash) }
      return false unless optional?(document[:runtime]) { |runtime| runtime.is_a?(Numeric) }

      Dash::Report.from_h(document).lines
      true
    end

    def optional?(value)
      value.nil? || yield(value)
    end

    def list_of_hashes?(value)
      value.is_a?(Array) && value.all?(Hash)
    end
end
