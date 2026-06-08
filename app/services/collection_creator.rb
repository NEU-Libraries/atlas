# frozen_string_literal: true

class CollectionCreator < ApplicationService
  # Provenance kwargs mirror WorkCreator — see app/services/work_creator.rb
  # for the rationale. Optional so direct callers (specs, reset.rake) work
  # without synthesizing an authenticated identity; the HTTP path supplies
  # them for every real-world create.
  # rubocop:disable Metrics/ParameterLists
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
    create_collection
  end

  private

    def create_collection
      collection = Atlas.persister.save(resource: Collection.new(a_member_of: @parent_id))

      FileSetCreator.call(work_id: collection.id, classification: Classification.descriptive_metadata)

      collection.mods_xml = @mods_xml

      # Order matters: parent.permissions copy lands BEFORE provenance
      # stamping so the parent's depositor/proxy_uploader doesn't clobber
      # values supplied for this create. See WorkCreator for the same
      # ordering invariant.
      collection.permissions = collection.parent.permissions
      apply_provenance!(collection)
      collection.add_edit_group(Permissions::STAFF_EDIT_GROUP) # Default entry so DPS can work with all items
      collection = Atlas.persister.save(resource: collection)
      collection.write_preservation_envelope!
      emit_audit_event!(collection)
      collection
    end

    def apply_provenance!(collection)
      return apply_impersonation_provenance!(collection) if @on_behalf_of_nuid.present?
      return if @proxy_uploader.nil? && @depositor.nil?

      collection.proxy_uploader = @proxy_uploader if @proxy_uploader
      collection.depositor      = @depositor      if @depositor
      collection.depositor    ||= @proxy_uploader
    end

    # Acting-as: pure impersonation — depositor = target, proxy_uploader
    # explicitly NULL. See WorkCreator#apply_impersonation_provenance! for
    # the full rationale (incl. why it's cleared, not skipped).
    def apply_impersonation_provenance!(collection)
      collection.proxy_uploader = nil
      collection.depositor      = @depositor if @depositor
      collection.depositor    ||= @on_behalf_of_nuid
    end

    def emit_audit_event!(collection)
      return if @actor_nuid.blank?

      on_behalf = @on_behalf_of_nuid || attribution_target(collection)
      AuditEventWriter.record(
        resource:          collection,
        actor_nuid:        @actor_nuid,
        on_behalf_of_nuid: on_behalf,
        action:            'create',
        change_type:       'structural',
        event_source:      'controller'
      )
      # A Collection always has a parent, so its starting ACL is always inherited.
      emit_permissions_grant!(collection, actor_nuid: @actor_nuid, on_behalf_of_nuid: on_behalf,
                                          source: 'inherited', parent_noid: collection.parent&.noid)
    end

    def attribution_target(collection)
      return nil if collection.depositor.blank?
      return nil if collection.depositor == @actor_nuid

      collection.depositor
    end
end
