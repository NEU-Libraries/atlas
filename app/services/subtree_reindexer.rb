# frozen_string_literal: true

# Re-projects a set of resources' Solr docs so their denormalized
# ancestor_ids_ssim reflects a structural move. Solr-only (via
# Atlas.index_adapter) — never rewrites Postgres or bumps optimistic-lock
# tokens, since Postgres a_member_of is already correct and is the source of
# truth this recomputes from.
#
# Idempotent and order-independent by construction: each save re-runs the
# AncestryIndexer, which recomputes the chain from live a_member_of edges in
# Postgres — not from any sibling's (possibly stale) Solr cache. So re-running
# the whole set, or running it in any order, converges to the same result.
#
# Synchronous by design. Atlas does not own background-job infrastructure
# (orchestration lives in Cerberus); a move is rare and bounded by the ~3k
# collections. The BATCH_SIZE slicing bounds memory and lets a future caller
# (Cerberus, for an exceptionally large community move) drive the cascade in
# chunks via repeated endpoint calls rather than Atlas growing a job runner.
class SubtreeReindexer < ApplicationService
  BATCH_SIZE = 500

  def initialize(resources:)
    @resources = Array(resources)
  end

  def call
    @resources.each_slice(BATCH_SIZE) do |batch|
      batch.each { |resource| Atlas.index_adapter.persister.save(resource: resource) }
    end
    @resources.size
  end
end
