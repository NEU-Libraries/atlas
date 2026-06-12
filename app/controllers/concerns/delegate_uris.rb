# frozen_string_literal: true

# Shared dispatcher for the purpose-specific PATCH endpoints that attach
# IIIF Delegate URIs to a resource — currently `/thumbnails` (thumbnail /
# thumbnail_2x / preview), `/image_derivatives` (small / medium / large)
# and the per-FileSet `/iiif_service` (uri). Each action picks one of
# the named helpers below; non-blank entries in `params` are upserted
# via DelegateUpdater.
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

  # Single-role mapping: the per-page IIIF image-service pointer (the
  # Cantaloupe base for the page's JP2). A viewer derives any size on
  # demand via info.json, so unlike the Work-level mappings there is no
  # tier family to enumerate.
  IIIF_SERVICE_ROLES = {
    'uri' => Role.service_file
  }.freeze

  private

    def apply_thumbnail_uris(resource_id:, source: params)
      apply_delegate_uris(resource_id: resource_id, mapping: THUMBNAIL_ROLES, source: source)
    end

    def apply_image_derivative_uris(resource_id:, source: params)
      apply_delegate_uris(resource_id: resource_id, mapping: IMAGE_DERIVATIVE_ROLES, source: source)
    end

    def apply_iiif_service_uri(resource_id:, source: params)
      apply_delegate_uris(resource_id: resource_id, mapping: IIIF_SERVICE_ROLES, source: source)
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
