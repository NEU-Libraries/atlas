# frozen_string_literal: true

# A Delegate carries Blob-shaped structural metadata (use, label,
# mime_type, original_filename) but no held binary — instead it points
# at an asset that lives elsewhere via `uri` (an IIIF URL for image
# derivatives, anything else for future uses). Used as the member of a
# `:derivative` FileSet to represent sized image variants (thumbnail,
# small, medium, large) without Atlas physically storing them.
#
# Delegates and the :derivative FileSets that wrap them are
# intentionally NOT preservation-relevant — they are regenerable
# derivatives, fungible from the original binary, and are excluded
# from the OCFL envelope per the preservation-first principle.
class Delegate < Resource
  include LeafReadAuthority

  attribute :mime_type, Valkyrie::Types::String
  attribute :original_filename, Valkyrie::Types::String
  attribute :use, Valkyrie::Types::String
  attribute :label, Valkyrie::Types::String
  attribute :uri, Valkyrie::Types::String
  # The pixel size of the image `uri` serves, and a tiny base64 JPEG of it, so
  # a client can reserve the image's frame and paint a blurred stand-in before
  # the image arrives. Only the preview tier sets them; see docs/binaries.md.
  attribute :width, Valkyrie::Types::Integer.optional
  attribute :height, Valkyrie::Types::Integer.optional
  attribute :placeholder, Valkyrie::Types::String
end
