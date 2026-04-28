# frozen_string_literal: true

# Regenerate the METS XML for a FileSet from its current Blob membership.
# Idempotent: a no-op when the freshly-built XML matches what's on disk.
class METSRebuilder < ApplicationService
  include METSBuilder
  include METSExtraction

  def initialize(file_set:)
    @file_set = reload(file_set)
  end

  def call
    return @file_set if @file_set.nil?
    return @file_set if Classification.metadata?(@file_set.type)
    return @file_set if @file_set.send(:structural_metadata_file_set).nil?

    new_xml = mets_for(@file_set, blobs: live_blobs, created_at: existing_created_at)
    return @file_set if new_xml == @file_set.mets_xml

    @file_set.mets_xml = new_xml
    @file_set
  end

  private

    def reload(file_set)
      return nil if file_set.nil?

      id = file_set.respond_to?(:id) ? file_set.id : file_set
      FileSet.find(id)
    end

    def live_blobs
      @file_set.files.compact
    end

    def existing_created_at
      current_blob = @file_set.mets_blob
      return nil if current_blob.nil? || current_blob.file.blank?

      extract_mets_created_at(Nokogiri::XML(current_blob.file.read, &:noblanks))
    end
end
