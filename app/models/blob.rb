# frozen_string_literal: true

class Blob < Resource
  attribute :mime_type, Valkyrie::Types::String
  attribute :original_filename, Valkyrie::Types::String
  attribute :file_identifiers, Valkyrie::Types::Set.of(Valkyrie::Types::ID).meta(ordered: true)
  attribute :use, Valkyrie::Types::String
  attribute :label, Valkyrie::Types::String # Small Image, Text etc.
  attribute :size, Valkyrie::Types::String
  # Self-describing fixity digest of the head revision's bytes, recorded at
  # ingest as "<algorithm>:<hexvalue>" (e.g. "sha512:abc…"). A denormalized
  # cache of the OCFL inventory's digest (the canonical source) — like `size`,
  # it keeps the fixity read path off the storage layer so reconciliation can
  # compare expected vs. stored without streaming bytes back down.
  attribute :digest, Valkyrie::Types::String

  def versions
    file_identifiers.count
  end

  def latest_revision
    return nil if file_identifiers.blank?

    file_identifiers.last.id
  end

  def file
    return nil if latest_revision.blank?

    Valkyrie.config.storage_adapter.find_by(id: latest_revision)
  end

  def path
    file&.io&.path
  end

  def extension
    original_filename&.split('.')&.last
  end

  def filename
    return if label.blank?

    "#{Label.find(label)&.prefix}#{noid}.#{extension}"
  end

  def metadata?
    use == Role.descriptive_metadata.name || use == Role.structural_metadata.name
  end

  # Blobs are graph leaves with no a_member_of / member_ids of their own —
  # parent linkage lives one hop up in the FileSet's member_ids. What they
  # do carry is preservation-critical descriptive payload (use, label,
  # filename, mime, size). The most load-bearing is `use`: it's what tells
  # a reconstitution tool that descMetadata.xml is MODS, not a content blob.
  def graph_payload
    {
      schema_version:    Preservable::ENVELOPE_SCHEMA_VERSION,
      noid:              noid,
      type:              'Blob',
      use:               use,
      original_filename: original_filename,
      mime_type:         mime_type,
      size:              size,
      label:             label
    }
  end

  def graph_filename
    'properties.json'
  end
end
