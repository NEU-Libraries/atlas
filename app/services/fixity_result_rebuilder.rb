# frozen_string_literal: true

# Recomputes fixity_results from every object's logs/fixity.jsonl: the newest
# line per object becomes its row, and a row whose object has no log goes. The
# rows are derived, so this is their recovery path. Reads every object, so an
# operator task, never a request. See docs/fixity.md.
#
# Only the resources whose rows change are re-indexed, so a rebuild that finds
# no drift costs no Solr writes.
class FixityResultRebuilder < ApplicationService
  def initialize(adapter: Valkyrie.config.storage_adapter)
    @adapter    = adapter
    @unreadable = 0
  end

  def call
    recorded = FixityResult.all.index_by(&:object_key)
    logged   = latest_lines
    changed  = logged.reject { |key, line| current?(recorded[key], line) }
    stale    = recorded.keys - logged.keys

    changed.each { |key, line| FixityResult.set!(key: key, **line) }
    FixityResult.where(object_key: stale).delete_all
    (changed.keys + stale).each { |key| reindex(key) }

    { logged: logged.size, corrected: changed.size, removed: stale.size, unreadable_lines: @unreadable }
  end

  private

    def latest_lines
      @adapter.storage_roots.keys
              .flat_map { |name| @adapter.object_keys(root_name: name) }
              .filter_map { |key| (line = latest_line(key)) && [key, line] }
              .to_h
    end

    # A line that does not parse is counted and skipped rather than fatal: one
    # damaged line must not leave every other object without its row.
    def latest_line(key)
      @adapter.read_log(key: key, name: FixityCheckRecorder::LOG_NAME)
              .filter_map { |raw| parse(raw) }
              .max_by { |line| line[:checked_at] }
    end

    def parse(raw)
      hash = JSON.parse(raw)
      { checked_at: Time.iso8601(hash.fetch('checked_at')), result: hash.fetch('result'),
        version: hash.fetch('version'), checker: hash.fetch('checker') }
    rescue JSON::ParserError, KeyError, ArgumentError, TypeError
      @unreadable += 1
      nil
    end

    def current?(row, line)
      row.present? && row.checked_at == line[:checked_at] && row.result == line[:result] &&
        row.version == line[:version] && row.checker == line[:checker]
    end

    # The owner's reindex carries the Work rollup; see FixityCheckRecorder.
    def reindex(key)
      resource = Resource.find(key)
      Atlas.reindex(resource) if resource && StorageFootprintQuery::OWNER_TYPES.exclude?(resource.class.name)
      StorageFootprintRecorder.note(key)
    end
end
