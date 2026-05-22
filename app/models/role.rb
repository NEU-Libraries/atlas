# frozen_string_literal: true

# Roles a Blob or Delegate can play within its parent FileSet (`use`).
# Mirrors the PCDM Use vocabulary (http://pcdm.org/use#) as a plain
# Enumerations::Base sibling of Classification and Label, with
# Atlas-specific extensions for metadata-bearing files and for the
# sized image-derivative tiers consumed by Cerberus's UI.
class Role < Enumerations::Base
  # PCDM Use vocabulary
  value :extracted_text,        name: 'Extracted Text'
  value :intermediate_file,     name: 'Intermediate File'
  value :original_file,         name: 'Original File'
  value :preservation_file,     name: 'Preservation File'
  value :service_file,          name: 'Service File'
  value :thumbnail_image,       name: 'Thumbnail Image'
  value :transcript,            name: 'Transcript'

  # Atlas extensions: sized image derivatives. The downloadable trio
  # surfaces in /works/:id/assets; the UI tier stays out of downloads
  # but is projected onto the parent resource JSON for Cerberus to
  # consume via flat fields and onto Solr docs via ThumbnailIndexer.
  value :small_image,           name: 'Small Image'         # downloadable
  value :medium_image,          name: 'Medium Image'        # downloadable
  value :large_image,           name: 'Large Image'         # downloadable
  value :preview_image,         name: 'Preview Image'       # UI: largest thumbnail (~500w)
  value :thumbnail_image_2x,    name: 'Thumbnail Image 2x'  # UI: retina catalog (~170)

  # Atlas extensions for metadata-bearing files
  value :descriptive_metadata,  name: 'Descriptive Metadata'
  value :structural_metadata,   name: 'Structural Metadata'

  # Roles that should NOT surface in a Work's downloadable-assets list:
  # thumbnail_image / thumbnail_image_2x / preview_image are UI chrome;
  # metadata roles are internal envelope material. New Role values are
  # downloadable by default — add to this list to opt out.
  NON_DOWNLOADABLE = [
    thumbnail_image.name,
    thumbnail_image_2x.name,
    preview_image.name,
    descriptive_metadata.name,
    structural_metadata.name
  ].freeze

  def self.downloadable?(name)
    NON_DOWNLOADABLE.exclude?(name)
  end
end
