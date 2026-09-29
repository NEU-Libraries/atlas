# frozen_string_literal: true

# Appends a content revision to a Blob, NOID preserved. A replace and a rollback
# both land here and differ only in where the bytes come from and what the
# revision is called. See docs/binaries.md.
class BlobRevisionAppender < ApplicationService
  include FileHelper
  include MimeHelper

  # name is the revision's filename: the replacement's own, or the kept one.
  def initialize(blob:, source_path:, name:)
    @blob        = blob
    @source_path = source_path
    @name        = name
  end

  # @return [Array(Blob, Valkyrie::ID)] the saved Blob and the version id cut.
  def call
    version_id = create_file(@source_path, @blob, logical_name).version_id
    @blob.file_identifiers += [version_id]
    @blob.record_revision_filename(version_id, @name)
    refresh_head_facts(version_id)

    saved = Atlas.persister.save(resource: @blob)
    saved.write_preservation_envelope!
    follow_classification(saved.parent) if primary?
    METSRebuilder.call(file_set: saved.parent) if saved.parent.is_a?(FileSet)
    [saved, version_id]
  end

  private

    # The OCFL logical path, so the object on disk names each revision's file.
    # basename because the name arrives from the caller.
    def logical_name
      File.basename(@name.to_s).presence || File.basename(@source_path)
    end

    # A read-path cache over the storage layer, so each revision re-derives it: a
    # stale size is what a consumer sets Content-Length and Range arithmetic
    # from. The MIME hint is the revision's filename, never the staged upload's
    # temp name, which Marcel reads as octet-stream.
    #
    # Only a primary is relabelled. A derivative's label names its tier, and
    # default_label would call any image an Original Image.
    def refresh_head_facts(version_id)
      @blob.digest    = recorded_digest(version_id)
      @blob.size      = File.size(@source_path)
      @blob.mime_type = mime_type(@source_path, name: @name)
      @blob.label     = default_label(@source_path, name: @name).symbol if primary?
    end

    def primary?
      @blob.use == Role.original_file.name
    end

    # Consumers branch on the FileSet's classification (the IIIF pipeline, the
    # zipped download), so a primary that changes type takes it along.
    def follow_classification(file_set)
      return unless file_set.is_a?(FileSet) && !Classification.metadata?(file_set.type)

      classification = assign_classification(@source_path, name: @name).name
      return if file_set.type == classification

      file_set.type = classification
      Atlas.persister.save(resource: file_set).write_preservation_envelope!
    end
end
