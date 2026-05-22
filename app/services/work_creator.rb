# frozen_string_literal: true

class WorkCreator < ApplicationService
  # Provenance kwargs are all optional so direct callers (specs,
  # reset.rake, ApplicationService.call from internal code) don't have to
  # synthesize an authenticated identity. The HTTP path (WorksController)
  # supplies them for every real-world create, which is when the
  # AuditEvent row is emitted.
  # rubocop:disable Metrics/ParameterLists
  # Each kwarg is a distinct dimension of "what this create is" (parent,
  # body, provenance, audit attribution). Compressing into a hash would
  # hide the public contract.
  def initialize(parent_id:, mods_xml: nil, proxy_uploader: nil,
                 depositor: nil, actor_nuid: nil, on_behalf_of_nuid: nil)
    # rubocop:enable Metrics/ParameterLists
    @parent_id         = resolve_id(parent_id)
    @mods_xml          = mods_xml.nil? ? mods_template : mods_xml
    @proxy_uploader    = proxy_uploader
    @depositor         = depositor
    @actor_nuid        = actor_nuid
    @on_behalf_of_nuid = on_behalf_of_nuid
  end

  def call
    create_work
  end

  private

    def create_work
      work = Atlas.persister.save(resource: Work.new(a_member_of: @parent_id))

      FileSetCreator.call(work_id: work.id, classification: Classification.descriptive_metadata)

      work.mods_xml = @mods_xml

      # Order matters: permissions = parent.permissions copies the parent's
      # depositor / proxy_uploader fields onto this Work. Any provenance
      # stamping for *this* create has to land AFTER the copy, or the
      # parent's values will overwrite it.
      work.permissions = work.parent.permissions
      apply_provenance!(work)
      work.add_edit_group(Permissions::STAFF_EDIT_GROUP) # Default entry so DPS can work with all items
      work = Atlas.persister.save(resource: work)
      work.write_preservation_envelope!
      emit_audit_event!(work)
      work
    end

    def apply_provenance!(work)
      return if @proxy_uploader.nil? && @depositor.nil?

      work.proxy_uploader = @proxy_uploader if @proxy_uploader
      work.depositor      = @depositor      if @depositor
      # Self-deposit fallback: caller supplied only proxy_uploader and
      # the parent didn't carry a depositor — stamp the actor as
      # depositor too. The common case for non-proxy deposits.
      work.depositor ||= @proxy_uploader
    end

    def emit_audit_event!(work)
      return if @actor_nuid.blank?

      AuditEventWriter.record(
        resource:          work,
        actor_nuid:        @actor_nuid,
        on_behalf_of_nuid: @on_behalf_of_nuid || attribution_target(work),
        action:            'create',
        change_type:       'structural',
        event_source:      'controller'
      )
    end

    # When on_behalf_of wasn't supplied explicitly but the depositor
    # differs from the actor, the depositor *is* the implicit attribution
    # target (e.g., the in-band proxy radio case in WorksController).
    def attribution_target(work)
      return nil if work.depositor.blank?
      return nil if work.depositor == @actor_nuid

      work.depositor
    end
end
