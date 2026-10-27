# frozen_string_literal: true

# Records one fixity check result: appends it to the object's
# logs/fixity.jsonl, advances the object's FixityResult when it is the newest
# check, and re-indexes the resource that owns the object. Hashes nothing, so a
# web worker can afford it. See docs/fixity.md.
#
# The log is written first because it is the record; the row and the index are
# caches over it, and `rake atlas:fixity:rebuild` repairs them if a later step
# fails.
class FixityCheckRecorder < ApplicationService
  LOG_NAME = 'fixity.jsonl'

  def initialize(check:, adapter: Valkyrie.config.storage_adapter)
    @check   = check
    @adapter = adapter
  end

  # The resource, whether the log gained a line, and whether this check is now
  # the object's latest. Nil when no resource holds the NOID.
  def call
    resource = Resource.find(@check.key)
    return nil if resource.nil?

    check_version!
    appended = @adapter.append_log(key: @check.key, name: LOG_NAME, line: @check.to_log_line) == :appended
    FixityResult.advance!(key: @check.key, checked_at: @check.checked_at, result: @check.result,
                          version: @check.version, checker: @check.checker)
    reindex(resource)
    { resource: resource, appended: appended, latest: latest? }
  end

  private

    # Solr only: a save through the persister would move updated_at, which is
    # the OAI datestamp, and every sweep would make harvesters re-fetch every
    # Work. The owning Work's rollup rides the footprint recorder's batched
    # owner reindex, so a request touching several of its objects reindexes it
    # once.
    def reindex(resource)
      Atlas.reindex(resource) unless StorageFootprintQuery::OWNER_TYPES.include?(resource.class.name)
      StorageFootprintRecorder.note(@check.key)
    end

    def check_version!
      versions = @adapter.object_versions(key: @check.key)
      raise Exceptions::FixityCheckError.new(:object_missing, "no OCFL object for #{@check.key}") if versions.nil?
      return if versions.include?(@check.version)

      raise Exceptions::FixityCheckError.new(:unknown_version, "#{@check.key} has no version #{@check.version}")
    end

    def latest?
      FixityResult.find_by(object_key: @check.key)&.checked_at == @check.checked_at
    end
end
