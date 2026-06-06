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

  # The security-relevant grants worth recording on a permissions change.
  # Provenance slots (depositor / proxy_uploader) are excluded — they carry
  # their own ledger via the creator / reparent paths.
  AUDITED_ACL_KEYS = %i[read edit edit_users].freeze

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

  # Apply a metadata PATCH (title / description / permissions, + the test-only
  # noid override), persist, re-emit the preservation envelope, and write the
  # provenance row(s). Extracted here because Works / Collections / Communities
  # drive this identically; returns the saved resource for the caller to assign.
  def audited_metadata_update(resource)
    metadata           = params[:metadata]
    before_permissions = apply_metadata_params(resource, metadata)
    saved              = Atlas.persister.save(resource: resource)
    saved.write_preservation_envelope!
    audit_metadata_update!(resource: saved, metadata: metadata, before_permissions: before_permissions)
    saved
  end

  private

    # Map the metadata params onto the resource. Returns the pre-edit ACL when
    # the request carried a permissions key (captured BEFORE reassignment so
    # the permissions audit row can record before/after), otherwise nil.
    def apply_metadata_params(resource, metadata)
      # custom noid is a test-only affordance
      resource.alternate_ids = metadata['noid'] if Rails.env.test? && metadata['noid'].present?
      before_permissions = resource.permissions if metadata['permissions'].present?
      resource.plain_title = metadata['title'] if metadata['title'].present?
      resource.plain_description = metadata['description'] if metadata['description'].present?
      resource.permissions = metadata['permissions'] if metadata['permissions'].present?
      before_permissions
    end

    # A metadata PATCH can change descriptive fields AND permissions in one
    # request, but change_type is one column per row and each carries different
    # provenance value — so emit up to two semantically-pure rows: a `metadata`
    # row listing the changed descriptive fields, and a `permissions` row
    # carrying the before/after ACL.
    def audit_metadata_update!(resource:, metadata:, before_permissions:)
      fields = %w[title description].select { |f| metadata[f].present? }
      audit!(resource: resource, action: 'update', change_type: 'metadata', payload: { fields: fields }) if fields.any?

      return if before_permissions.nil?

      audit!(resource: resource, action: 'update', change_type: 'permissions',
             payload: { before: acl_snapshot(before_permissions), after: acl_snapshot(resource.permissions) })
    end

    def acl_snapshot(permissions)
      permissions.slice(*AUDITED_ACL_KEYS)
    end
end
