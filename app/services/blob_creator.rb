# frozen_string_literal: true

class BlobCreator < ApplicationService
  include FileHelper
  include MimeHelper

  def initialize(work_id:, path:, file_set_id: nil)
    @work_id = resolve_id(work_id) if !work_id.nil?
    @path = path
    @file_set_id = file_set_id
  end

  def call
    create_blob
  end

  private

    def create_blob
      if @work_id
        classification = assign_classification(@path)
        # Collection.new(a_member_of: @parent_id)
        fs = FileSetCreator.call(work_id: @work_id, classification: classification)
      else
        fs = FileSet.find(@file_set_id)
      end

      b = Valkyrie.config.metadata_adapter.persister.save(resource: Blob.new)

      fs.member_ids += [b.id]
      Valkyrie.config.metadata_adapter.persister.save(resource: fs)

      file_id = create_file(@path, b).id
      b.file_identifiers += [file_id]
      Valkyrie.config.metadata_adapter.persister.save(resource: b)
    end
end
