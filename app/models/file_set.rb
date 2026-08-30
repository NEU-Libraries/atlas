# frozen_string_literal: true

class FileSet < Resource
  include LeafReadAuthority
  include Metsable

  attribute :type, Valkyrie::Types::String # no default - comes from assignment
  attribute :member_ids, Valkyrie::Types::Set.of(Valkyrie::Types::ID)
  attribute :a_member_of, Valkyrie::Types::ID

  # idempotency
  attribute :derivative_for, Valkyrie::Types::ID.optional

  # 1-based page order within the parent Work (multipage Works). nil =
  # unordered — every non-multipage FileSet stays nil forever. Atlas stores
  # what it is given; contiguity/uniqueness validation is the loader's job
  # upstream. The canonical preservation record of order is the Work-level
  # METS structMap; this attribute is its denormalized runtime projection.
  attribute :position, Valkyrie::Types::Integer.optional

  def files
    @files ||= member_ids.map { |id| Blob.find(id) }
  end

  # Page-bearing = content-carrying: not a metadata container (descriptive
  # MODS / structural METS) and not a :derivative container. Drives the
  # ordered listing (works#file_sets) and the Work-level METS structMap.
  def page?
    !Classification.metadata?(type) && type != Classification.derivative.name
  end

  # User-facing content blobs only — excludes metadata-marked Blobs (METS,
  # future flat-MODS) so callers iterating over a FileSet's payload don't
  # accidentally treat the manifest as content.
  def content_files
    files.compact.reject(&:metadata?)
  end

  # def original_file?
  #   files.any? { |f| f&.use == Role.original_file.name }
  # end
end
