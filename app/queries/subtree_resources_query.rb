# frozen_string_literal: true

# Gathers a resource together with its full descendant subtree, for an
# index-refresh (POST /resources/:id/reindex_subtree). Returns the root plus:
#
#   1. every descendant CONTAINER (Collection/Community) — one Solr lookup
#      against the denormalized ancestor_ids_ssim (DescendantCollectionsQuery), and
#   2. every WORK hanging off the root or any descendant container — the direct
#      members of each (a_member_of inverse refs + ordered member_ids), deduped
#      by id so a Work linked into several Collections appears once.
#
# This is deliberately a SUPERSET of the re-parent cascade. Reparenter gathers
# containers ONLY, because a move recomputes ancestor_ids_ssim and Works don't
# carry that field ("Works are never part of a cascade"). A reindex, by
# contrast, refreshes *any* projection — including classification_ssim, which
# lives on Works — so the Works must be in the set. The generic
# SubtreeReindexer just saves whatever resources it's given, so the fuller set
# fed here is all it takes.
#
# Container reach is transitive in a single query: ancestor_ids_ssim holds the
# *entire* ancestor chain, so every descendant container at any depth comes
# back from the one lookup; gathering each container's direct Work members then
# covers every Work in the subtree.
class SubtreeResourcesQuery
  def self.call(resource)
    new(resource).call
  end

  def initialize(resource)
    @resource = resource
  end

  def call
    containers = [@resource] + @resource.descendant_collections
    works = containers.flat_map(&:children).select { |child| child.is_a?(Work) }
    (containers + works).uniq(&:id)
  end
end
