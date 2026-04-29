# frozen_string_literal: true

class CollectionCreator < ApplicationService
  def initialize(parent_id:, mods_xml: nil)
    @parent_id = resolve_id(parent_id)
    @mods_xml = mods_xml.nil? ? mods_template : mods_xml
  end

  def call
    create_collection
  end

  private

    def create_collection
      collection = Atlas.persister.save(resource: Collection.new(a_member_of: @parent_id))

      FileSetCreator.call(work_id: collection.id, classification: Classification.descriptive_metadata)

      collection.mods_xml = @mods_xml
      collection.permissions = collection.parent.permissions
      collection.add_edit_group('northeastern:drs:repository:staff') # Default entry so DPS can work with all items
      collection = Atlas.persister.save(resource: collection)
      collection.write_preservation_envelope!
      collection
    end
end
