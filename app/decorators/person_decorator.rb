# frozen_string_literal: true

# View-layer helpers for Person. The stored affiliation edges are Valkyrie ids
# (an implementation detail); the public id everywhere in Atlas is the NOID, so
# the JSON surfaces affiliated communities as NOIDs. Resolved in one batched
# query (a Person has a handful of affiliations) rather than per-edge.
module PersonDecorator
  def affiliated_community_noids
    ids = Array(affiliated_community_ids)
    return [] if ids.empty?

    Atlas.query.find_many_by_ids(ids: ids).map(&:noid)
  end
end
