# frozen_string_literal: true

# Regenerate the METS XML for a FileSet from its current Blob membership.
# Idempotent: a no-op when the freshly-built XML matches what's on disk.
class METSRebuilder < ApplicationService
  include METSBuilder
  include METSExtraction

  def initialize(file_set:)
    @file_set = reload(file_set)
  end

  # Two uploads into one FileSet each rebuild its METS. As in WorkMETSRebuilder,
  # the first build's lock runs them one at a time, each reloading under it.
  def call
    return if @file_set.nil?

    AdvisoryLock.hold('mets', @file_set.id) do
      StaleRetry.run("METS rebuild of FileSet #{@file_set.noid}") do
        @file_set = reload(@file_set)
        rebuild
      end
    end
  end

  private

    def rebuild
      return @file_set if @file_set.nil?
      return @file_set if Classification.metadata?(@file_set.type)

      created_at, last_modified = existing_dates
      blobs = @file_set.content_files
      # Built with the stored LASTMODDATE first, so an unchanged FileSet
      # compares equal and cuts no OCFL version.
      unchanged = mets_for(@file_set, blobs: blobs, created_at: created_at, last_modified: last_modified)
      return @file_set if last_modified.present? && unchanged == @file_set.mets_xml

      @file_set.mets_xml = mets_for(@file_set, blobs: blobs, created_at: created_at)
      @file_set
    end

    def reload(file_set)
      return nil if file_set.nil?

      id = file_set.respond_to?(:id) ? file_set.id : file_set
      FileSet.find(id)
    end

    def existing_dates
      current_blob = @file_set.mets_blob
      return [nil, nil] if current_blob.nil? || current_blob.file.blank?

      doc = Nokogiri::XML(current_blob.file.read, &:noblanks)
      [extract_mets_created_at(doc), extract_mets_last_modified(doc)]
    end
end
