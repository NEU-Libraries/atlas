# frozen_string_literal: true

# Denormalizes a Collection/Community's full ancestor chain into Solr so
# the "everything beneath this collection" (descendant) question becomes a
# reverse lookup — `fq=ancestor_ids_ssim:"<noid>"` — instead of a subtree
# walk. This moves the cost from every read to the rare write (a re-parent).
#
# Collections and Communities ONLY. Works are excluded by design: they are
# the ~544k bulk of the graph and have no descendants, so carrying the field
# on them would turn every re-parent into a full-graph cascade. The
# work-exclusion is the whole reason this projection is cheap.
#
# Index-only: not a persisted attribute. Postgres `a_member_of` stays the
# single source of truth; this field is recomputed from it at index time,
# so it cannot drift. Values are raw NOIDs (collections + communities),
# order irrelevant (exact-match multivalued string field).
#
# NB: the value shape (raw noids) differs from a_member_of_tesim
# (id-<uuid>). Descendant reverse-queries match on noid; direct-membership
# queries match on id-<uuid>. Documented in the cross-repo handoff.
class AncestryIndexer
  attr_reader :resource

  def initialize(resource:)
    @resource = resource
  end

  def to_solr
    return {} unless resource.is_a?(Collection) || resource.is_a?(Community)

    { 'ancestor_ids_ssim' => resource.ancestors.map { |noid, _klass| noid } }
  end
end
