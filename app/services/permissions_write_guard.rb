# frozen_string_literal: true

# Vets an incoming ACL envelope before it reaches Permissions#permissions=, and
# returns the payload that should actually be written. Two rules, both of which
# need context the setter doesn't have — the structural parent, and the acting
# user:
#
#   1. **Containment.** A resource may be no more visible than its container.
#      The Creators establish the invariant by copying parent.permissions; this
#      keeps it true across edits, which matters because gated discovery filters
#      on the resource's own read groups with no ancestry term — a public Work
#      inside a restricted Collection is discoverable and downloadable by anyone
#      while its parent 403s. Refused with a 422 rather than silently clamped:
#      the caller asked for an audience it may not have.
#
#   2. **Grant removal.** A group grant may only be removed by a member of that
#      group; admins and the devolved-admin tier are exempt. Preserved grants
#      are merged back rather than 403'd, mirroring how STAFF_EDIT_GROUP is
#      handled — the payload is a full-replacement list, so "omitted because the
#      caller's UI made the row read-only" and "deliberately removed" are
#      indistinguishable on the wire, and rejecting would break a well-behaved
#      client that renders those rows without a remove control. Merge-back is
#      also audit-clean: the no-op suppression in Auditable compares
#      post-setter ACLs, so a preserved grant writes no spurious row.
#
# Adding grants is unconstrained by rule 2 (it only bounds the destructive
# direction) but still bounded by rule 1.
class PermissionsWriteGuard < ApplicationService
  # `public` is a visibility token, not a Grouper group: nobody is a member of
  # it, so under rule 2 it would be permanently unremovable — which would stop a
  # depositor from making their own resource private. Their own item's
  # visibility is theirs to set, so removal of this token is always allowed.
  ALWAYS_REMOVABLE = ['public'].freeze

  # Envelope keys carrying group lists, paired with the resource reader holding
  # the current value. `edit_users` is deliberately absent — rule 2 is about
  # group membership and says nothing about individual grants.
  GROUP_KEYS = { 'read' => :read_groups, 'edit' => :edit_groups }.freeze

  def initialize(resource:, incoming:, actor: nil)
    @resource = resource
    @incoming = incoming
    @actor    = actor
  end

  def call
    payload = normalized_payload
    validate_containment!(payload)
    preserve_locked_groups(payload)
  end

  private

    # ActionController::Parameters (the controller path) and a plain Hash (an
    # internal caller) both normalize to indifferent access, which is what
    # Permissions#permissions= reads through.
    def normalized_payload
      return @incoming.to_unsafe_h if @incoming.respond_to?(:to_unsafe_h)

      @incoming.to_h.with_indifferent_access
    end

    # A resource with no structural parent — a root Community — has nothing to
    # be contained by. Validated against the payload as submitted (the caller's
    # stated intent) rather than the post-merge-back value, so a pre-existing
    # violation preserved by rule 2 can't fail an otherwise legitimate write.
    def validate_containment!(payload)
      parent = @resource.parent
      return if parent.nil?
      return if TierVisibility.audience_subset?(Array(payload['read']), Array(parent.read_groups))

      raise Exceptions::PermissionsError.new(
        :visibility_exceeds_parent, 'a resource cannot be more visible than its parent'
      )
    end

    def preserve_locked_groups(payload)
      return payload if exempt_from_removal_rule?

      GROUP_KEYS.each do |key, reader|
        incoming = Array(payload[key])
        locked   = (Array(@resource.public_send(reader)) - incoming).reject { |group| removable?(group) }
        payload[key] = incoming + locked if locked.any?
      end
      payload
    end

    def removable?(group)
      ALWAYS_REMOVABLE.include?(group) || Array(@actor&.groups).include?(group)
    end

    # Operators may remove any grant. A nil actor (an internal caller with no
    # request context) is not exempt — it has no group membership to appeal to,
    # so it keeps the conservative behaviour.
    def exempt_from_removal_rule?
      @actor&.admin? || @actor&.admin_delegate? || false
    end
end
