# frozen_string_literal: true

# Removes a linked membership: drops a Collection from a Work's
# a_linked_member_of Set. Idempotent — removing a link that isn't present is a
# harmless no-op. Permissions are untouched (linking never carried any).
#
# Note the "dormant, not pruned" principle lives elsewhere: drift from
# permission/visibility changes is handled by Cerberus's gated discovery
# (a restricted Work simply stops matching the ACL filter), not by removing
# links. This service only removes a link on explicit operator request.
class LinkedMemberRemover < ApplicationService
  def initialize(work:, collection:, actor_nuid: nil, on_behalf_of_nuid: nil)
    @work              = work
    @collection        = collection
    @actor_nuid        = actor_nuid
    @on_behalf_of_nuid = on_behalf_of_nuid
  end

  def call
    @work.a_linked_member_of = Array(@work.a_linked_member_of).reject { |id| id.to_s == @collection.id.to_s }
    @work = Atlas.persister.save(resource: @work)
    emit_audit_event!
    @work
  end

  private

    def emit_audit_event!
      return if @actor_nuid.blank?

      AuditEventWriter.record(
        resource:          @work,
        actor_nuid:        @actor_nuid,
        on_behalf_of_nuid: @on_behalf_of_nuid,
        action:            'unlink_member',
        change_type:       'structural',
        event_source:      'controller',
        payload:           { collection: @collection.noid }
      )
    end
end
