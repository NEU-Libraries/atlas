# frozen_string_literal: true

# Projects the bytes a Work, Collection or Community owns on disk onto its Solr
# doc as storage_bytes_ls, so a subtree's storage is a Solr sum over the docs a
# subtree filter already selects. See docs/binaries.md.
#
# Own bytes only, never a subtree total: a total would change on every write
# anywhere beneath, and on every move.
class StorageIndexer
  attr_reader :resource

  def initialize(resource:)
    @resource = resource
  end

  def to_solr
    return {} unless StorageFootprintQuery::OWNER_TYPES.include?(resource.class.name)

    { storage_bytes_ls: StorageFootprintQuery.own_bytes(resource) }
  end
end
