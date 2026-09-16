# frozen_string_literal: true

# Vets an incoming ACL envelope before it reaches Permissions#permissions= and
# returns the payload that should actually be written. Two rules -- containment
# and grant removal -- both needing context the setter doesn't have: the
# structural parent, and the acting user. See docs/authorization.md for the
# argument behind each.
class PermissionsWriteGuard < ApplicationService
  # A visibility token, not a Grouper group: nobody is a member of it, so under
  # the removal rule it would be permanently unremovable, which would stop a
  # depositor making their own resource private.
  ALWAYS_REMOVABLE = ['public'].freeze

  # `edit_users` is deliberately absent: the removal rule is about group
  # membership and says nothing about individual grants.
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

    # Both callers normalize to indifferent access, which is what
    # Permissions#permissions= reads through.
    def normalized_payload
      return @incoming.to_unsafe_h if @incoming.respond_to?(:to_unsafe_h)

      @incoming.to_h.with_indifferent_access
    end

    # Validated against the payload as submitted -- the caller's stated intent
    # -- rather than the post-merge-back value, so a pre-existing violation
    # preserved by the removal rule can't fail an otherwise legitimate write.
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

    # A nil actor is NOT exempt: it has no group membership to appeal to, so it
    # keeps the conservative behaviour.
    def exempt_from_removal_rule?
      @actor&.admin? || @actor&.admin_delegate? || false
    end
end
