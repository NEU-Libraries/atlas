# frozen_string_literal: true

# Shared dispatcher for the purpose-specific PATCH endpoints that attach
# IIIF Delegate URIs to a resource — currently `/thumbnails` (thumbnail /
# thumbnail_2x / preview) and `/image_derivatives` (small / medium /
# large). Each action picks one of the named helpers below; non-blank
# entries in `params` are upserted via DelegateUpdater.
#
# Programmatic Delegate writes used to ride the generic `metadata[…]`
# PATCH bag; that overload is gone — each Delegate-write surface now has
# its own route and its own atlas_rb binding.
module DelegateUris
  extend ActiveSupport::Concern

  THUMBNAIL_ROLES = {
    'thumbnail'    => Role.thumbnail_image,
    'thumbnail_2x' => Role.thumbnail_image_2x,
    'preview'      => Role.preview_image
  }.freeze

  IMAGE_DERIVATIVE_ROLES = {
    'small'  => Role.small_image,
    'medium' => Role.medium_image,
    'large'  => Role.large_image
  }.freeze

  private

    def apply_thumbnail_uris(resource_id:, source: params)
      apply_delegate_uris(resource_id: resource_id, mapping: THUMBNAIL_ROLES, source: source)
    end

    def apply_image_derivative_uris(resource_id:, source: params)
      apply_delegate_uris(resource_id: resource_id, mapping: IMAGE_DERIVATIVE_ROLES, source: source)
    end

    def apply_delegate_uris(resource_id:, mapping:, source:)
      mapping.each do |key, role|
        next if source[key].blank?

        DelegateUpdater.call(
          resource_id: resource_id,
          use:         role.name,
          uri:         source[key]
        )
      end
    end
end
