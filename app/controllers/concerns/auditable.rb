# frozen_string_literal: true

# Controller-side provenance emission. The structural mutations already emit
# from their service objects; this closes the content, metadata, lifecycle and
# file gap with a one-line emit at each save point. See docs/write-safety.md.
module Auditable
  extend ActiveSupport::Concern

  # Free text from the wire lands in a jsonb column, so it is capped.
  ORIGIN_MAX_LENGTH = 64

  # The actor is the authenticated principal, NOT the `User:` header -- the
  # signed-assertion relay does not send one. No-ops for a guest: a guest
  # carries no provenance, and actor_nuid is NOT NULL.
  def audit!(resource:, action:, change_type:, payload: {}, note: nil)
    return if @current_user.nil? || @current_user.guest?

    AuditEventWriter.record(
      resource:          resource,
      actor_nuid:        @current_user.nuid,
      on_behalf_of_nuid: @on_behalf_of.presence,
      action:            action,
      change_type:       change_type,
      event_source:      'controller',
      payload:           payload,
      note:              note
    )
  end

  # `source` is matched EXACTLY by downstream renderers, so the editing
  # surface rides beside it in `origin` rather than overloading it. Atlas
  # stores `origin` verbatim and never branches on it, so a new surface needs
  # no Atlas change. The key is omitted when the caller sends nothing.
  def mods_audit_payload
    origin = params[:origin].to_s.strip
    return { source: 'mods' } if origin.empty?

    { source: 'mods', origin: origin.truncate(ORIGIN_MAX_LENGTH) }
  end

  # Descriptive fields are NOT writable through the ACL path: the only MODS
  # write is the caller-assembled raw mods_xml= upload, and descriptive merges
  # belong to the client. Extracted because every resource type drives it
  # identically, which is what let the endpoint become type-agnostic.
  def audited_permissions_update(resource, incoming)
    before_acl = apply_permissions(resource, incoming)
    saved      = Atlas.persister.save(resource: resource)
    saved.write_preservation_envelope!
    audit_metadata_update!(resource: saved, before_acl: before_acl)
    saved
  end

  private

    # before_acl is captured BEFORE reassignment, so the audit row can record
    # both sides and a no-op write can be detected.
    #
    # The single funnel every ACL write passes through, and the only place
    # carrying both the acting user and the pre-edit state -- which is why
    # PermissionsWriteGuard applies here.
    def apply_permissions(resource, incoming)
      return nil if incoming.blank?

      before_acl = resource.audited_acl
      resource.permissions = PermissionsWriteGuard.call(resource: resource,
                                                        incoming: incoming,
                                                        actor:    @current_user)
      before_acl
    end

    # A write whose effective ACL is unchanged is a non-event. Comparing the
    # POST-SETTER normalized ACLs, staff auto-prepend included, is what
    # suppresses the spurious "Updated - Permissions" row.
    def audit_metadata_update!(resource:, before_acl:)
      return if before_acl.nil?

      after_acl = resource.audited_acl
      return if acl_equivalent?(before_acl, after_acl)

      audit!(resource: resource, action: 'update', change_type: 'permissions',
             payload: { before: before_acl, after: after_acl })
    end

    # A group list differing only in order is the same grant. The payload
    # still records the ACLs in their stored order.
    def acl_equivalent?(before, after)
      normalize = ->(acl) { acl.transform_values { |v| v.is_a?(Array) ? v.sort : v } }
      normalize.call(before) == normalize.call(after)
    end
end
