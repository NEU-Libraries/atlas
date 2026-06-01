# frozen_string_literal: true

# Reverse of the ancestry walk: given a Collection/Community, find every
# resource whose denormalized ancestor chain (ancestor_ids_ssim, emitted by
# AncestryIndexer) includes it. This is the "everything beneath this node"
# query that compute-on-read ancestry couldn't answer without touring the
# subtree — here it's one Solr exact-match lookup.
#
# Returns Collection and Community resources (both carry ancestor_ids_ssim);
# Works are deliberately excluded from the field, so they never appear here.
# Used by the re-parent cycle guard (is the destination one of my
# descendants?) and the re-parent cascade (which docs need re-projection).
class DescendantCollectionsQuery
  # Branching lives only among the ~3k collections, so a single un-paginated
  # fetch is safe and simplest. Bump if the backbone ever grows past this.
  ROWS = 10_000

  def self.call(resource)
    new(resource).call
  end

  def initialize(resource)
    @resource = resource
  end

  def call
    docs = Atlas.index_adapter.connection.get(
      'select',
      params: { q: '*:*', fq: %(ancestor_ids_ssim:"#{@resource.noid}"), rows: ROWS, fl: 'id' }
    ).dig('response', 'docs') || []

    ids = docs.map { |doc| Valkyrie::ID.new(doc['id']) }
    return [] if ids.empty?

    Atlas.query.find_many_by_ids(ids: ids).to_a
  end
end
