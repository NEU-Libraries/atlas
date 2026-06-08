# frozen_string_literal: true

class ApplicationService
  include MODSBuilder
  include NoidHelper

  def self.call(**kwargs)
    new(**kwargs).call
  end

  private

    # Emit the create-time `permissions` audit event: the ACL the resource is
    # *born* carrying, whether copied from a parent (Work/Collection, and a
    # nested Community) or the values a root Community is created with. Without
    # this, the meaningful "nothing -> public/staff" grant happens silently
    # inside the inheritance copy and never appears in Rights history.
    #
    # Shape mirrors the manual-edit permissions event (before/after audited
    # ACL) and adds ModsVersions-style provenance: `source` ("inherited" /
    # "initial") and a `note` naming the parent for inherited grants. Guarded on
    # actor presence exactly like the structural create event, so internal
    # callers (reset.rake, specs) that supply no actor emit nothing.
    def emit_permissions_grant!(resource, actor_nuid:, on_behalf_of_nuid:, source:, parent_noid: nil)
      return if actor_nuid.blank?

      AuditEventWriter.record(
        resource:          resource,
        actor_nuid:        actor_nuid,
        on_behalf_of_nuid: on_behalf_of_nuid,
        action:            'create',
        change_type:       'permissions',
        event_source:      'controller',
        payload:           { before: {}, after: resource.audited_acl, source: source },
        note:              parent_noid && "inherited from #{parent_noid}"
      )
    end
end
