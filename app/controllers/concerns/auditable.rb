# frozen_string_literal: true

# Controller-side provenance emission for resource edit / lifecycle / file
# paths. The structural mutations (create, reparent, link/unlink) already emit
# from their service objects; this concern closes the *content/metadata/
# lifecycle/file* gap by giving the three resource controllers (and the blob
# controller) a one-line emit at each save point, closing over the actor
# plumbing the controllers already carry (`@nuid` operator, `@on_behalf_of`
# attribution target — set in ApplicationController#parse_headers).
module Auditable
  extend ActiveSupport::Concern

  # Emit a controller-sourced audit row for `resource`. actor / on-behalf-of
  # and event_source are filled from request context so call sites stay to one
  # line. No-ops when there is no authenticated actor: a row with no
  # actor_nuid carries no provenance (and the column is NOT NULL), so guest
  # reads and any upstream-authorized path lacking a User header write nothing.
  def audit!(resource:, action:, change_type:, payload: {}, note: nil)
    return if @nuid.blank?

    AuditEventWriter.record(
      resource:          resource,
      actor_nuid:        @nuid,
      on_behalf_of_nuid: @on_behalf_of.presence,
      action:            action,
      change_type:       change_type,
      event_source:      'controller',
      payload:           payload,
      note:              note
    )
  end

  # Apply a metadata PATCH (permissions, + the test-only noid override),
  # persist, re-emit the preservation envelope, and write the provenance
  # row(s). Descriptive fields (title / description) are NOT writable here —
  # the only MODS write path is the caller-assembled raw `mods_xml=` (binary
  # upload); descriptive merges belong to the client (Cerberus / MODSMerge),
  # not Atlas. Extracted here because Works / Collections / Communities drive
  # this identically; returns the saved resource for the caller to assign.
  def audited_metadata_update(resource)
    metadata   = params[:metadata]
    before_acl = apply_metadata_params(resource, metadata)
    saved      = Atlas.persister.save(resource: resource)
    saved.write_preservation_envelope!
    audit_metadata_update!(resource: saved, before_acl: before_acl)
    saved
  end

  private

    # Map the metadata params onto the resource. Only permissions (and the
    # test-only noid override) are writable here; title / description keys are
    # silently ignored — the descriptive write path is the raw `mods_xml=`
    # binary upload, not this PATCH. Returns the pre-edit audited ACL when the
    # request carried a permissions key (captured BEFORE reassignment so the
    # permissions audit row can record before/after and so a no-op write can be
    # detected), otherwise nil.
    def apply_metadata_params(resource, metadata)
      # custom noid is a test-only affordance
      resource.alternate_ids = metadata['noid'] if Rails.env.test? && metadata['noid'].present?
      before_acl = resource.audited_acl if metadata['permissions'].present?
      resource.permissions = metadata['permissions'] if metadata['permissions'].present?
      before_acl
    end

    # The metadata PATCH only mutates permissions, so it emits at most one
    # `permissions` row carrying the before/after ACL. (Descriptive `metadata`
    # rows now come solely from the binary `mods_xml=` path, tagged
    # `{ source: 'mods' }` by the controller's binary_update.)
    #
    # A permissions write whose effective ACL is unchanged (e.g. re-saving the
    # Permissions tab without edits, or re-applying an inherited ACL) is a
    # non-event — comparing the post-setter normalized ACLs (incl. the staff
    # auto-prepend) suppresses the spurious "Updated · Permissions" row.
    def audit_metadata_update!(resource:, before_acl:)
      return if before_acl.nil?

      after_acl = resource.audited_acl
      return if acl_equivalent?(before_acl, after_acl)

      audit!(resource: resource, action: 'update', change_type: 'permissions',
             payload: { before: before_acl, after: after_acl })
    end

    # Order-insensitive ACL comparison for no-op detection: a group list that
    # differs only in order is the same grant, so sort array values before
    # comparing. The payload still records the ACLs in their stored order.
    def acl_equivalent?(before, after)
      normalize = ->(acl) { acl.transform_values { |v| v.is_a?(Array) ? v.sort : v } }
      normalize.call(before) == normalize.call(after)
    end
end
