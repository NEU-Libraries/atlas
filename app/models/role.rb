# frozen_string_literal: true

# Roles a Blob can play within its parent FileSet (Blob#use).
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
end
