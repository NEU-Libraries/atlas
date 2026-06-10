# frozen_string_literal: true

class Work < Resource
  include Metsable

  # The one structural home (Tree). Scalar — a Work lives in exactly one
  # Collection. Mirrors FileSet's existing scalar a_member_of.
  attribute :a_member_of, Valkyrie::Types::ID
  # The many discovery links (DAG overlay). A Work can be a "linked member"
  # of additional Collections without duplicating the object. Leaves-only:
  # only Works carry this; the collection/community backbone stays a strict
  # tree, so cycles are structurally impossible. Adds placement, never
  # permission — the Work keeps its single ACL.
  attribute :a_linked_member_of, Valkyrie::Types::Set.of(Valkyrie::Types::ID)
  attribute :type, Valkyrie::Types::String.default(Classification.work.name.freeze)

  # Operator-visibility flag: Cerberus's bulk-deposit jobs leave this true
  # until they've confirmed all expected children are deposited, then flip
  # it to false via POST /works/:id/complete. Indexed in Solr so the
  # /works?in_progress=true monitoring query can find stuck deposits.
  attribute :in_progress, Valkyrie::Types::Bool.default(true)

  # Page-bearing FileSets in presentation order: position ASC, unordered
  # (nil) last, creation-order tie-break — a total order even over
  # legacy/unordered data. Shared by works#file_sets and the Work-level
  # METS structMap so the runtime read and the preservation record can't
  # disagree.
  def page_file_sets
    children
      .select { |c| c.is_a?(FileSet) && c.page? }
      .sort_by { |fs| [fs.position.nil? ? 1 : 0, fs.position || 0, fs.created_at] }
  end

  # Work-level METS lives in a sibling :structural_metadata FileSet (the
  # MODS/descriptive-metadata shape) — a Work has no member_ids, and its
  # children stay exclusively FileSets. Overrides Metsable's flat
  # member_ids storage, which fits FileSet but not Work.
  def mets_blob
    structural_metadata_file_set&.files&.compact&.find { |b| b.use == Role.structural_metadata.name }
  end

  private

    def structural_metadata_file_set
      children.find { |c| c.is_a?(FileSet) && c.type == Classification.structural_metadata.name }
    end

    # Created lazily at first METS write (i.e. at /complete) — existing
    # Works need no backfill, and never-completed Works never grow one.
    # Mirrors Modsable#create_mods_blob's sibling-FileSet shape.
    def create_mets_blob
      fs = structural_metadata_file_set ||
           FileSetCreator.call(work_id: id, classification: Classification.structural_metadata)
      blob = Atlas.persister.save(resource: Blob.new(use: Role.structural_metadata.name))
      fs.member_ids += [blob.id]
      Atlas.persister.save(resource: fs)
      blob.write_preservation_envelope!
      fs.write_preservation_envelope!
      blob
    end
end
