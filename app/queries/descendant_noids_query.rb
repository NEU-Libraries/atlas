# frozen_string_literal: true

# Every NOID beneath a container, Works and sub-containers alike, for cache
# eviction. Both embed the container's title and chain in their `ancestors`.
#
# The sibling of DescendantWorksQuery, minus everything eviction does not need:
# no ACL gating (a cache entry is dropped for every caller at once), no
# pagination, no digest — just the ids. Solr-projected at both steps, so
# clearing a 10k-Work collection never materializes a Valkyrie resource.
#
# Deliberately NOT SubtreeResourcesQuery, which walks `children` and builds
# every descendant object. This runs inside a write, and a container rename must not
# cost a subtree materialization.
class DescendantNoidsQuery
  include SolrRefs

  # Works far outnumber containers, so this is its own bound rather than
  # SolrRefs::CONTAINER_ROWS. A subtree past this many descendants evicts the
  # first slice and lets the rest age out on TTL — a stale ancestor title for up
  # to an hour, not a wrong ACL.
  ROWS = 50_000

  def self.call(resource)
    new(resource).call
  end

  def initialize(resource)
    @resource = resource
  end

  def call
    refs = container_refs([@resource.noid.to_s])
    return [] if refs.empty?

    docs = connection.get(
      'select',
      params: { q: '*:*', rows: ROWS, fl: 'alternate_ids_ssim',
                fq: "a_member_of_ssi:(#{refs.join(' ')})" }
    ).dig('response', 'docs') || []

    # alternate_ids_ssim stores the reference form (`id-<noid>`), not the bare
    # NOID the cache keys on — the same hop OAI::Record and
    # OAISetMembershipQuery make.
    docs.filter_map { |doc| Array(doc['alternate_ids_ssim']).first&.to_s&.delete_prefix('id-') }.uniq
  end
end
