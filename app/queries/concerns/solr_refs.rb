# frozen_string_literal: true

# The reference vocabulary every Solr-side membership query speaks. Valkyrie's
# join fields store `id-<uuid>` while the API speaks NOIDs, and doing that hop
# in one place keeps the gated digest engine and the OAI feed from drifting on
# what "member of this container" means. See docs/read-performance.md.
module SolrRefs
  extend ActiveSupport::Concern

  # Matches DescendantCollectionsQuery::ROWS. Branching lives among the ~3k
  # collections, and works never appear here.
  CONTAINER_ROWS = 10_000

  private

    def connection
      Atlas.index_adapter.connection
    end

    # ancestor_ids_ssim carries DESCENDANTS ONLY, so the roots are unioned in
    # explicitly. A noid that no longer resolves matches nothing.
    def container_refs(noids)
      return [] if noids.empty?

      descendants = solr_ids("{!terms f=ancestor_ids_ssim}#{noids.join(',')}")
      roots       = solr_ids("{!terms f=alternate_ids_ssim}#{noids.map { |n| "id-#{n}" }.join(',')}")
      (descendants + roots).uniq.map { |uuid| %("id-#{uuid}") }
    end

    def solr_ids(filter)
      docs = connection.get(
        'select',
        params: { q: '*:*', fq: filter, rows: CONTAINER_ROWS, fl: 'id' }
      ).dig('response', 'docs') || []
      docs.pluck('id')
    end

    def solr_ref(noid)
      %("id-#{noid}")
    end
end
