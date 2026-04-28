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

      seed_mets(fs) if seed_mets?
      fs
    end

    def seed_mets?
      !Classification.metadata?(@classification.name)
    end

    def seed_mets(file_set)
      FileSetCreator.call(work_id: file_set.id, classification: Classification.structural_metadata)
      file_set.mets_xml = file_set.mets_template
    end
end
