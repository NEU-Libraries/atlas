# frozen_string_literal: true

# The reference vocabulary every Solr-side membership query speaks.
#
# Valkyrie's join fields (a_member_of_ssi, a_linked_member_of_ssim) store
# `id-<uuid>` — the Valkyrie id — while the API and the recipe tables speak
# NOIDs. Resolving one to the other is the hop these helpers exist for, and
# doing it in one place keeps the two consumers (WorkDigestQuery's gated
# digest engine and the OAI provider's cursor-paged feed) from drifting apart
# on what "member of this container" means.
module SolrRefs
  extend ActiveSupport::Concern

  # Container fan-out bound — matches DescendantCollectionsQuery::ROWS
  # (branching lives among the ~3k collections; works never appear here).
  CONTAINER_ROWS = 10_000

  private

    def connection
      Atlas.index_adapter.connection
    end

    # Covered containers as quoted id-<uuid> references (the value shape
    # a_member_of_ssi / a_linked_member_of_ssim store). ancestor_ids_ssim speaks
    # raw noids and carries descendants only, so the roots are unioned in
    # explicitly via alternate_ids_ssim. The uuid hop happens here — the join
    # fields store uuids. A noid that no longer resolves simply matches nothing.
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
