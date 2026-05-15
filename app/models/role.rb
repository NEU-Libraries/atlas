# frozen_string_literal: true

# Roles a Blob or Delegate can play within its parent FileSet (`use`).
# Mirrors the PCDM Use vocabulary (http://pcdm.org/use#) as a plain
# Enumerations::Base sibling of Classification and Label, with two
# Atlas-specific extensions for metadata-bearing files.
class Role < Enumerations::Base
  # PCDM Use vocabulary
  value :extracted_text,        name: 'Extracted Text'
  value :intermediate_file,     name: 'Intermediate File'
  value :original_file,         name: 'Original File'
  value :preservation_file,     name: 'Preservation File'
  value :service_file,          name: 'Service File'
  value :thumbnail_image,       name: 'Thumbnail Image'
  value :transcript,            name: 'Transcript'

  # Atlas extensions for metadata-bearing files
  value :descriptive_metadata,  name: 'Descriptive Metadata'
  value :structural_metadata,   name: 'Structural Metadata'

  # Roles that should NOT surface in a Work's downloadable-assets list:
  # thumbnail_image is UI chrome; metadata roles are internal envelope
  # material. New Role values are downloadable by default — add to this
  # list to opt out.
  NON_DOWNLOADABLE = [
    thumbnail_image.name,
    descriptive_metadata.name,
    structural_metadata.name
  ].freeze

  def self.downloadable?(name)
    !NON_DOWNLOADABLE.include?(name)
  end
end
