# frozen_string_literal: true

class BlobCreator < ApplicationService
  include FileHelper
  include MimeHelper

  def initialize(path:, work_id: nil, file_set_id: nil, original_filename: nil, use: nil)
    @work_id = resolve_id(work_id) unless work_id.nil?
    @path = path
    @file_set_id = file_set_id
    @original_filename = original_filename
    @use = use || Role.original_file.name
  end

  def call
    create_blob
  end

  private

    def create_blob
      fs   = resolve_file_set
      blob = save_initial_blob
      attach_to_file_set(fs, blob)
      blob = upload_and_save(blob)
      METSRebuilder.call(file_set: fs)
      blob
    end

    def resolve_file_set
      if @work_id
        FileSetCreator.call(work_id: @work_id, classification: assign_classification(@path))
      else
        FileSet.find(@file_set_id)
      end
    end

    def save_initial_blob
      label = default_label(@path)
      Atlas.persister.save(
        resource: Blob.new(
          original_filename: @original_filename,
          mime_type:         mime_type(@path),
          size:              File.size(@path),
          label:             label&.symbol || '', # TODO: temporary nil fix until we zip unknowns
          use:               @use
        )
      )
    end

    def attach_to_file_set(file_set, blob)
      file_set.member_ids += [blob.id]
      file_set = Atlas.persister.save(resource: file_set)
      file_set.write_preservation_envelope!
    end

    def upload_and_save(blob)
      blob.file_identifiers += [create_file(@path, blob).version_id]
      # TODO: implement bespoke Blob permissions for differentiated access
      blob.permissions = Work.find(@work_id).permissions if @work_id
      blob = Atlas.persister.save(resource: blob)
      blob.write_preservation_envelope!
      blob
    end
end
