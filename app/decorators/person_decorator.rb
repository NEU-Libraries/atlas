# frozen_string_literal: true

# View-layer helpers for Person. The stored affiliation edges are Valkyrie ids
# (an implementation detail); the public id everywhere in Atlas is the NOID, so
# the JSON surfaces affiliated communities as NOIDs. Resolved in one batched
# query (a Person has a handful of affiliations) rather than per-edge.
module PersonDecorator
  def affiliated_community_noids
    return @affiliated_community_noids if defined?(@affiliated_community_noids)

    ids = Array(affiliated_community_ids)
    return [] if ids.empty?

    @affiliated_community_noids = Atlas.query.find_many_by_ids(ids: ids.map(&:to_s)).map(&:noid)
  end

  # Seed the resolution from a batched read (PersonAffiliationPreloader). The
  # per-Person query is already batched over one Person's handful of edges; the
  # People index renders a page of them, so the fan-out is over rows.
  def preload_affiliated_communities(noids)
    @affiliated_community_noids = Array(noids)
  end
end
