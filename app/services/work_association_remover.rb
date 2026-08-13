# frozen_string_literal: true

# Retracts a typed relationship between two Works. Idempotent — retracting
# an edge that was never asserted is a harmless no-op — so it needs no
# validate! step, mirroring LinkedMemberRemover.
#
# The type is part of the edge's identity, not a filter on it: two Works can
# hold two different edges at once, and retracting the figure claim must
# leave the transcription claim standing.
class WorkAssociationRemover < ApplicationService
  def initialize(work:, target:, type:, actor_nuid: nil, on_behalf_of_nuid: nil)
    @work              = work
    @target            = target
    @type              = type.to_s
    @actor_nuid        = actor_nuid
    @on_behalf_of_nuid = on_behalf_of_nuid
  end

  def call
    return @work unless Work::ASSOCIATION_TYPES.include?(predicate)

    @work.set_value(predicate, Array(@work[predicate]).reject { |id| id.to_s == @target.id.to_s })
    @work = Atlas.persister.save(resource: @work)
    @work.write_preservation_envelope!
    emit_audit_event!
    @work
  end

  private

    def predicate
      @predicate ||= @type.to_sym
    end

    def emit_audit_event!
      return if @actor_nuid.blank?

      AuditEventWriter.record(
        resource:          @work,
        actor_nuid:        @actor_nuid,
        on_behalf_of_nuid: @on_behalf_of_nuid,
        action:            'disassociate',
        change_type:       'metadata',
        event_source:      'controller',
        payload:           { target: @target.noid, type: @type }
      )
    end
end
