# frozen_string_literal: true

# See docs/resource-graph.md: the graph shape, the lifecycle flags, and which
# derived attributes reach the preservation envelope.
class Work < Resource
  include Metsable
  include TierVisibility

  # The SUBORDINATE Work stores the edge; the other end is read back with
  # find_inverse_references_by, so the reverse edge cannot drift. Five named
  # attributes because that query needs a real property, not an encoded string.
  ASSOCIATION_TYPES = %i[is_codebook_for is_figure_for is_instructional_material_for
                         is_supplemental_material_for is_transcription_of].freeze

  ASSOCIATION_TYPES.each do |predicate|
    attribute predicate, Valkyrie::Types::Set.of(Valkyrie::Types::ID)
  end

  # Scalar: a Work lives in exactly one Collection.
  attribute :a_member_of, Valkyrie::Types::ID
  # The DAG overlay, leaves-only, so the backbone stays a strict tree and
  # cycles are impossible. Adds placement, never permission.
  attribute :a_linked_member_of, Valkyrie::Types::Set.of(Valkyrie::Types::ID)
  attribute :type, Valkyrie::Types::String.default(Classification.work.name.freeze)

  attribute :in_progress, Valkyrie::Types::Bool.default(true)

  # FLAGS and never hides: a missing derivative is degraded, not broken.
  attribute :incomplete, Valkyrie::Types::Bool.default(false)

  # Deliberately NOT validated: the vocabulary belongs to Cerberus, the only
  # writer, so a new token must not need an Atlas release to be accepted.
  attribute :incomplete_reason, Valkyrie::Types::String.optional

  # Unlike the fields below this one IS preservation-relevant: nothing here
  # can re-derive the binding, so it rides the OCFL envelope (schema v5).
  attribute :handle, Valkyrie::Types::String.optional

  # A regenerable search aid, NOT a preservation artifact, so it is omitted
  # from the OCFL envelope. Unbounded-ish in size.
  attribute :full_text, Valkyrie::Types::String

  # A JSON STRING and not a Types::Hash: the metadata adapter collapses
  # single-element arrays ({"small"=>["public"]} becomes {"small"=>"public"}),
  # corrupting the group sets. Read through TierVisibility, never raw.
  attribute :derivative_permissions, Valkyrie::Types::String

  # A TOTAL order even over legacy unordered data, shared by works#file_sets
  # and the METS structMap so the two cannot disagree.
  def page_file_sets
    children
      .select { |c| c.is_a?(FileSet) && c.page? }
      .sort_by { |fs| [fs.position.nil? ? 1 : 0, fs.position || 0, fs.created_at] }
  end

  # Overrides Metsable's flat member_ids storage: a Work has no member_ids,
  # so its METS Blob hangs off a sibling :structural_metadata FileSet.
  def mets_blob
    files = structural_metadata_file_set&.files
    files&.compact&.find { |b| b.use == Role.structural_metadata.name }
  end

  private

    def structural_metadata_file_set
      children.find { |c| c.is_a?(FileSet) && c.type == Classification.structural_metadata.name }
    end

    # Lazy, so existing Works need no backfill.
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
