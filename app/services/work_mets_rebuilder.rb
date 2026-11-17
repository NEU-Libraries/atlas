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

  # A page can land while the Work is being finalized, so two rebuilds of one
  # Work can start together. The lock its first build takes runs them one at a
  # time, and each reloads under it, so a rebuild that waited writes nothing
  # when the XML already matches. The retry is for writers outside the lock.
  # See docs/write-safety.md.
  def call
    return if @work.nil?

    AdvisoryLock.hold('work_mets', @work.id) do
      StaleRetry.run("METS rebuild of Work #{@work.noid}") do
        @work = reload(@work)
        rebuild
      end
    end
  end

  private

    def rebuild
      return @work if @work.nil?

      new_xml = mets_for_work(@work, file_sets: @work.page_file_sets, created_at: existing_created_at)
      return @work if new_xml == @work.mets_xml

      @work.mets_xml = new_xml
      Work.find(@work.id) # reload: mets_xml= mutated children via persister, so the local work is stale
    end

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
