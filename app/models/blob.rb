# frozen_string_literal: true

class Blob < Resource
  include LeafReadAuthority

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
  # A caption's language (BCP 47) and the name a player shows for it. Blob-level,
  # not per revision: replacing a caption's bytes keeps its language.
  attribute :language, Valkyrie::Types::String
  # { OCFL version label => that revision's filename }, JSON-encoded because the
  # metadata adapter mangles Hash values. A replace can rename the file, so the
  # name belongs to the revision; original_filename is the head's. See
  # docs/binaries.md.
  attribute :revision_filenames, Valkyrie::Types::String
  attribute :track_label, Valkyrie::Types::String

  # BCP 47 in shape only. Atlas does not consult the IANA registry, so the
  # caller owns the vocabulary; this only stops a label landing in the field.
  LANGUAGE_FORMAT = /\A[a-z]{2,3}(-[a-z0-9]{1,8})*\z/i
  TRACK_LABEL_MAX_LENGTH = 64

  # Only the keys the caller sent, so an update never clears a field it did not
  # mention. A blank value clears. Raises Exceptions::BlobMetadataError.
  def self.track_fields(given)
    fields = given.to_h.stringify_keys.slice('language', 'track_label').transform_values { |v| v.to_s.strip.presence }
    validate_track_fields!(fields)
    fields.symbolize_keys
  end

  def self.validate_track_fields!(fields)
    if fields['language'] && !LANGUAGE_FORMAT.match?(fields['language'])
      raise Exceptions::BlobMetadataError.new(
        :invalid_language, "language must be a BCP 47 tag such as en or es-MX; got #{fields['language'].inspect}"
      )
    end
    return unless fields['track_label'] && fields['track_label'].length > TRACK_LABEL_MAX_LENGTH

    raise Exceptions::BlobMetadataError.new(:invalid_track_label,
                                            "track_label must be at most #{TRACK_LABEL_MAX_LENGTH} characters")
  end

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

  def revision_filenames_map
    return {} if revision_filenames.blank?

    JSON.parse(revision_filenames)
  rescue JSON::ParserError
    {}
  end

  # A Blob deposited before names were recorded per revision never changed its
  # name, so original_filename is right for every one of its revisions.
  def filename_at(version_label)
    revision_filenames_map.fetch(version_label.to_s, original_filename)
  end

  def filename_for(file_identifier)
    filename_at(revision_label(file_identifier))
  end

  # Call after appending file_identifier. Revisions from before names were
  # recorded are pinned to the current name first, so a rename cannot rewrite
  # what they were called.
  def record_revision_filename(file_identifier, name)
    map = revision_filenames_map
    file_identifiers.each { |fid| map[revision_label(fid)] ||= original_filename }
    map[revision_label(file_identifier)] = name
    self.revision_filenames = JSON.dump(map)
    self.original_filename = name
  end

  def extension
    original_filename&.split('.')&.last
  end

  def filename
    return if label.blank?

    "#{Label.find(label)&.prefix}#{noid}.#{extension}"
  end

  def metadata?
    [Role.descriptive_metadata.name, Role.structural_metadata.name, Role.darwin_core.name].include?(use)
  end

  # Blobs are graph leaves with no a_member_of / member_ids of their own —
  # parent linkage lives one hop up in the FileSet's member_ids. What they
  # do carry is preservation-critical descriptive payload (use, label,
  # filename, mime, size). The most load-bearing is `use`: it's what tells
  # a reconstitution tool that descMetadata.xml is MODS, not a content blob.
  def graph_payload
    {
      schema_version:     Preservable::ENVELOPE_SCHEMA_VERSION,
      noid:               noid,
      type:               'Blob',
      use:                use,
      original_filename:  original_filename,
      mime_type:          mime_type,
      size:               size,
      label:              label,
      language:           language,
      track_label:        track_label,
      revision_filenames: revision_filenames_map
    }
  end

  def graph_filename
    'properties.json'
  end

  private

    def revision_label(file_identifier)
      Valkyrie.config.storage_adapter.version_label_for(file_identifier)
    end
end
