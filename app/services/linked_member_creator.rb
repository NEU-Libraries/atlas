# frozen_string_literal: true

# Adds a linked membership: makes a Work a "linked member" of an additional
# Collection (the DAG overlay) without moving its structural home or touching
# its ACL. Validates BEFORE writing, then appends the Collection's id to the
# Work's a_linked_member_of Set (dedup'd — adding an existing link is a no-op).
#
# No permission change. The Work keeps its single authoritative ACL; linking
# adds placement, never permission. Escalation is structurally impossible and
# is enforced downstream by Cerberus's gated discovery (the linked clause is
# AND-ed with read_access_group_ssim), so there is no permission logic here.
class LinkedMemberCreator < ApplicationService
  def initialize(work:, collection:, actor_nuid: nil, on_behalf_of_nuid: nil)
    @work              = work
    @collection        = collection
    @actor_nuid        = actor_nuid
    @on_behalf_of_nuid = on_behalf_of_nuid
  end

  def call
    validate!

    @work.a_linked_member_of = (Array(@work.a_linked_member_of) + [@collection.id]).uniq(&:to_s)
    @work = Atlas.persister.save(resource: @work)
    emit_audit_event!
    @work
  end

  private

    def validate!
      raise_error('invalid_target_type', 'linked member target must be a Collection') unless @collection.is_a?(Collection)
      raise_error('tombstoned_work', 'cannot link a tombstoned work') if @work.tombstoned
      raise_error('tombstoned_target', 'cannot link into a tombstoned collection') if @collection.tombstoned
      raise_error('already_structural_member', 'work is already a structural member of this collection') if structural_member?
    end

    # A redundant link to the Work's one structural home adds nothing.
    def structural_member?
      @work.a_member_of.present? && @work.a_member_of.to_s == @collection.id.to_s
    end

    def emit_audit_event!
      return if @actor_nuid.blank?

      AuditEventWriter.record(
        resource:          @work,
        actor_nuid:        @actor_nuid,
        on_behalf_of_nuid: @on_behalf_of_nuid,
        action:            'link_member',
        change_type:       'structural',
        event_source:      'controller',
        payload:           { collection: @collection.noid }
      )
    end

    def raise_error(code, message)
      raise Exceptions::LinkedMemberError.new(code, message)
    end
end
