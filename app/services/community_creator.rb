# frozen_string_literal: true

class CommunityCreator < ApplicationService
  # Provenance kwargs mirror WorkCreator — see app/services/work_creator.rb.
  # Communities can be roots, so parent_id and the parent.permissions copy
  # are both conditional; provenance stamping happens whether or not a
  # parent is present.
  # rubocop:disable Metrics/ParameterLists
  def initialize(parent_id: nil, mods_xml: nil, proxy_uploader: nil,
                 depositor: nil, actor_nuid: nil, on_behalf_of_nuid: nil)
    # rubocop:enable Metrics/ParameterLists
    @parent_id         = resolve_id(parent_id) if parent_id.present?
    @mods_xml          = mods_xml.nil? ? mods_template : mods_xml
    @proxy_uploader    = proxy_uploader
    @depositor         = depositor
    @actor_nuid        = actor_nuid
    @on_behalf_of_nuid = on_behalf_of_nuid
  end

  def call
    create_community
  end

  private

    def create_community
      community = Atlas.persister.save(resource: Community.new(a_member_of: @parent_id))

      FileSetCreator.call(work_id: community.id, classification: Classification.descriptive_metadata)

      community.mods_xml = @mods_xml

      if community.parent.present?
        community.permissions = community.parent.permissions
        community.add_edit_group(Permissions::STAFF_EDIT_GROUP) # Default entry so DPS can work with all items
      end

      apply_provenance!(community)

      community = Atlas.persister.save(resource: community)
      community.write_preservation_envelope!
      emit_audit_event!(community)
      community
    end

    def apply_provenance!(community)
      return if @proxy_uploader.nil? && @depositor.nil?

      community.proxy_uploader = @proxy_uploader if @proxy_uploader
      community.depositor      = @depositor      if @depositor
      community.depositor    ||= @proxy_uploader
    end

    def emit_audit_event!(community)
      return if @actor_nuid.blank?

      AuditEventWriter.record(
        resource:          community,
        actor_nuid:        @actor_nuid,
        on_behalf_of_nuid: @on_behalf_of_nuid || attribution_target(community),
        action:            'create',
        change_type:       'structural',
        event_source:      'controller'
      )
    end

    def attribution_target(community)
      return nil if community.depositor.blank?
      return nil if community.depositor == @actor_nuid

      community.depositor
    end
end
