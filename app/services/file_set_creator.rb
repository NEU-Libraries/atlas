# frozen_string_literal: true

class FileSetCreator < ApplicationService
  def initialize(work_id:, classification:)
    @work_id = resolve_id(work_id)
    @classification = classification
  end

  def call
    create_file_set
  end

  private

    def create_file_set
      fs = FileSet.new(type: @classification.name)
      fs.a_member_of = @work_id
      fs = Atlas.persister.save(resource: fs)

      fs.permissions = fs.parent.permissions # TODO: need to work in Sentinels eventually
      fs = Atlas.persister.save(resource: fs)

      if seed_mets?
        fs.mets_xml = fs.mets_template
        fs = FileSet.find(fs.id) # reload: mets_xml= mutated self via persister, so the local fs is stale
      end

      fs.write_preservation_envelope! if Classification.preserved?(@classification.name)
      fs
    end

    def seed_mets?
      !Classification.metadata?(@classification.name) &&
        Classification.preserved?(@classification.name)
    end
end
