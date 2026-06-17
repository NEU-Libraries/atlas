# frozen_string_literal: true

class FileSetCreator < ApplicationService
  def initialize(work_id:, classification:, position: nil)
    @work_id = resolve_id(work_id)
    @classification = classification
    @position = position
  end

  def call
    fs = create_file_set
    rebuild_work_mets(fs)
    fs
  end

  private

    def create_file_set
      fs = FileSet.new(type: @classification.name, position: @position)
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

    # Eager-after-finalize: a page added to an already-completed Work must
    # show up in the preserved structMap immediately. During ingest
    # (in_progress) the rebuild waits for POST /works/:id/complete, so an
    # N-page deposit doesn't cut N OCFL versions on the way in. Metadata
    # and :derivative FileSets are not pages (this also breaks recursion:
    # the structural FileSet WorkMETSRebuilder itself creates lands here).
    def rebuild_work_mets(file_set)
      return unless file_set.page?

      work = file_set.parent
      return unless work.is_a?(Work) && work.in_progress == false

      work = WorkMETSRebuilder.call(work: work)
      reproject_classification(work)
    end

    # The page set of a completed Work just changed, so its content-type
    # projection (ClassificationIndexer -> classification_ssim, the catalog's
    # "Content" facet) is stale. Re-project the Work's Solr doc only —
    # Atlas.index_adapter never bumps the optimistic-lock token, so adding a
    # page can't 409 a concurrent edit of the Work. (At POST /works/:id/complete
    # the Work is composite-saved, so that path re-projects for free.)
    def reproject_classification(work)
      Atlas.index_adapter.persister.save(resource: work)
    end
end
