# frozen_string_literal: true

# Asserts a typed relationship from one Work to another: "this is the
# codebook for that dataset". Validates BEFORE writing, then appends the
# target's id to the matching predicate Set on the asserting Work
# (dedup'd — asserting an edge that already exists is a no-op).
#
# Only the asserting Work is written. The other end is read back with
# find_inverse_references_by, so there is no reciprocal edge to keep in step
# and no paired delete to unwind when either Work is withdrawn.
#
# No cycle guard, deliberately. "A is a transcription of B" and "B is a
# figure for A" are both meaningful statements, and nothing walks these
# edges recursively — they are curatorial claims about meaning, not
# containment. This is why they differ from a_member_of, which needs one.
class WorkAssociationCreator < ApplicationService
  def initialize(work:, target:, type:, actor_nuid: nil, on_behalf_of_nuid: nil)
    @work              = work
    @target            = target
    @type              = type.to_s
    @actor_nuid        = actor_nuid
    @on_behalf_of_nuid = on_behalf_of_nuid
  end

  def call
    validate!

    @work.set_value(predicate, (Array(@work[predicate]) + [@target.id]).uniq(&:to_s))
    @work = Atlas.persister.save(resource: @work)
    @work.write_preservation_envelope!
    emit_audit_event!
    @work
  end

  private

    def predicate
      @predicate ||= @type.to_sym
    end

    def validate!
      raise_error('invalid_type', "unknown association type #{@type}") unless valid_type?
      raise_error('invalid_target_type', 'target must be a Work') unless @target.is_a?(Work)
      raise_error('self_association', 'a work cannot be associated with itself') if same_work?
      raise_error('tombstoned_work', 'cannot associate a tombstoned work') if @work.tombstoned
      raise_error('tombstoned_target', 'cannot associate with a tombstoned work') if @target.tombstoned
    end

    def valid_type?
      Work::ASSOCIATION_TYPES.include?(predicate)
    end

    def same_work?
      @work.id.to_s == @target.id.to_s
    end

    def emit_audit_event!
      return if @actor_nuid.blank?

      AuditEventWriter.record(
        resource:          @work,
        actor_nuid:        @actor_nuid,
        on_behalf_of_nuid: @on_behalf_of_nuid,
        action:            'associate',
        # metadata, not structural: the edge is a curatorial claim about
        # meaning and moves nothing in the containment tree.
        change_type:       'metadata',
        event_source:      'controller',
        payload:           { target: @target.noid, type: @type }
      )
    end

    def raise_error(code, message)
      raise Exceptions::WorkAssociationError.new(code, message)
    end
end
