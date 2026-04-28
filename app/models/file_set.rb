# frozen_string_literal: true

class FileSet < Resource
  include Metsable

  attribute :type, Valkyrie::Types::String # no default - comes from assignment
  attribute :member_ids, Valkyrie::Types::Set.of(Valkyrie::Types::ID)
  attribute :a_member_of, Valkyrie::Types::ID

  # idempotency
  attribute :derivative_for, Valkyrie::Types::ID.optional

  def files
    @files ||= member_ids.map { |id| Blob.find(id) }
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
