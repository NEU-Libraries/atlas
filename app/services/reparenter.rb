# frozen_string_literal: true

# Moves a resource to a new structural parent, keeping the denormalized
# ancestry cache correct. Validates (type rules, cycle, tombstone) BEFORE any
# write, assigns the SCALAR a_member_of, then cascades a Solr-only re-index
# over the moved subtree's descendant collections. Works are never part of a
# cascade (they carry no ancestor_ids_ssim and have no descendants).
#
# Permissions are untouched — a move changes placement, not the ACL.
#
# Eventual consistency: the moved node and its descendants are re-projected
# in-request here, so by the time this returns the caches are fresh. (Were a
# move ever large enough to push the cascade async, a brief window of stale
# descendant caches would be acceptable — moves are rare.)
class Reparenter < ApplicationService
  # node class name => permitted parent classes. nil parent (top of tree) is
  # only valid for a Community, handled explicitly in validate_type!.
  ALLOWED_PARENTS = {
    'Work'       => %w[Collection],
    'Collection' => %w[Community Collection],
    'Community'  => %w[Community]
  }.freeze

  def initialize(node:, destination:, actor_nuid: nil, on_behalf_of_nuid: nil)
    @node              = node
    @destination       = destination
    @actor_nuid        = actor_nuid
    @on_behalf_of_nuid = on_behalf_of_nuid
  end

  def call
    validate!

    old_parent_noid = @node.parent&.noid
    # Captured BEFORE the move: the descendant SET is invariant under a
    # re-parent (descendants stay descendants; only their ancestor chain
    # changes), so this is the exact set of docs whose ancestor_ids_ssim
    # needs recomputing.
    subtree = descendants

    # assign_parent! does a composite save, refreshing the node's own Solr
    # doc; SubtreeReindexer then re-projects the descendants (Solr-only).
    assign_parent!
    SubtreeReindexer.call(resources: subtree)
    evict_descendant_response_cache!
    emit_audit_event!(old_parent_noid, subtree.size)

    @node
  end

  private

    # Descendant Works embed the moved node's chain in their `ancestors`, and
    # nothing re-saves them — SubtreeReindexer re-projects containers only, and
    # Works carry no ancestor field to re-project. So their cached bodies are
    # the one thing a move leaves stale, and they are dropped here rather than
    # left to age out. A Work move needs none of this: it has no descendants.
    def evict_descendant_response_cache!
      ResponseCache.evict(@node.noid)
      return if @node.is_a?(Work)

      ResponseCache.evict_many(DescendantWorkNoidsQuery.call(@node))
    end

    def validate!
      raise_reparent('tombstoned_node', 'cannot re-parent a tombstoned resource') if @node.tombstoned
      raise_reparent('tombstoned_parent', 'cannot re-parent into a tombstoned resource') if @destination&.tombstoned

      validate_type!
      validate_cycle!
    end

    def validate_type!
      if @destination.nil?
        return if @node.is_a?(Community) # only a Community may be parentless (top of tree)

        raise_reparent('parent_required', "#{@node.class.name} requires a parent")
      end

      allowed = ALLOWED_PARENTS.fetch(@node.class.name, [])
      return if allowed.include?(@destination.class.name)

      raise_reparent('invalid_parent_type',
                     "#{@node.class.name} cannot be a member of #{@destination.class.name}")
    end

    def validate_cycle!
      return if @destination.nil?

      raise_reparent('cycle', 'a resource cannot be its own parent') if @destination.id == @node.id

      # New parent must not live within the moved node's own subtree.
      # descendant_collections excludes Works, so this is a no-op for Works.
      return unless descendants.map(&:id).include?(@destination.id)

      raise_reparent('cycle', 'cannot move a resource into its own descendant')
    end

    # Memoized — both the cycle check and the cascade read this, and both run
    # before the move, so the descendant set is identical for both.
    def descendants
      @descendants ||= @node.descendant_collections
    end

    def assign_parent!
      @node.a_member_of = @destination&.id # scalar; nil clears it (top-level Community)
      @node = Atlas.persister.save(resource: @node)
    end

    def emit_audit_event!(old_parent_noid, subtree_size)
      return if @actor_nuid.blank?

      AuditEventWriter.record(
        resource:          @node,
        actor_nuid:        @actor_nuid,
        on_behalf_of_nuid: @on_behalf_of_nuid,
        action:            'reparent',
        change_type:       'structural',
        event_source:      'controller',
        payload:           { from: old_parent_noid, to: @destination&.noid, descendants_reindexed: subtree_size }
      )
    end

    def raise_reparent(code, message)
      raise Exceptions::ReparentError.new(code, message)
    end
end
