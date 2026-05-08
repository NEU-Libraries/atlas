# frozen_string_literal: true

class CommunityCreator < ApplicationService
  def initialize(parent_id: nil, mods_xml: nil)
    @parent_id = resolve_id(parent_id) if parent_id.present?
    @mods_xml = mods_xml.nil? ? mods_template : mods_xml
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

      community = Atlas.persister.save(resource: community)
      community.write_preservation_envelope!
      community
    end
end
