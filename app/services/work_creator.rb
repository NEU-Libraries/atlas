# frozen_string_literal: true

class WorkCreator < ApplicationService
  def initialize(parent_id:, mods_xml: nil)
    @parent_id = resolve_id(parent_id)
    @mods_xml = mods_xml.nil? ? mods_template : mods_xml
  end

  def call
    create_work
  end

  private

    def create_work
      work = Atlas.persister.save(resource: Work.new(a_member_of: @parent_id))

      FileSetCreator.call(work_id: work.id, classification: Classification.descriptive_metadata)

      work.mods_xml = @mods_xml
      work.permissions = work.parent.permissions # TODO: need to work in Sentinels eventually
      work = Atlas.persister.save(resource: work)
      work.write_preservation_envelope!
      work
    end
end
