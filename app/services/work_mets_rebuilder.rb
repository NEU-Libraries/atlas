# frozen_string_literal: true

# Regenerate the Work-level METS XML (physical structMap — the
# preservation record of page order) from the Work's current page
# FileSets. Idempotent: a no-op when the freshly-built XML matches
# what's on disk.
#
# Trigger discipline (finalize + eager-after): built at
# POST /works/:id/complete, then eagerly on FileSet create/destroy under
# an already-completed Work — never during an in-progress ingest, so an
# N-page deposit doesn't cut N OCFL versions on the way in.
class WorkMETSRebuilder < ApplicationService
  include METSWorkBuilder
  include METSExtraction

  def initialize(work:)
    @work = reload(work)
  end

  def call
    return @work if @work.nil?

    new_xml = mets_for_work(@work, file_sets: @work.page_file_sets, created_at: existing_created_at)
    return @work if new_xml == @work.mets_xml

    @work.mets_xml = new_xml
    Work.find(@work.id) # reload: mets_xml= mutated children via persister, so the local work is stale
  end

  private

    def reload(work)
      return nil if work.nil?

      id = work.respond_to?(:id) ? work.id : work
      Work.find(id)
    end

    def existing_created_at
      current_blob = @work.mets_blob
      return nil if current_blob.nil? || current_blob.file.blank?

      extract_mets_created_at(Nokogiri::XML(current_blob.file.read, &:noblanks))
    end
end
