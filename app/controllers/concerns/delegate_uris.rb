# frozen_string_literal: true

# Shared dispatcher for the purpose-specific PATCH endpoints that attach
# IIIF Delegate URIs to a resource — currently `/thumbnails` (thumbnail /
# thumbnail_2x / preview) and `/image_derivatives` (small / medium /
# large). Each action passes a {param_key => Role} mapping and the
# incoming params; non-blank entries are upserted via DelegateUpdater.
#
# Programmatic Delegate writes used to ride the generic `metadata[…]`
# PATCH bag; that overload is gone — each Delegate-write surface now has
# its own route and its own atlas_rb binding.
module DelegateUris
  extend ActiveSupport::Concern

  private

    def apply_delegate_uris(resource_id:, mapping:, source:)
      mapping.each do |key, role|
        next if source[key].blank?

        DelegateUpdater.call(
          resource_id: resource_id,
          use: role.name,
          uri: source[key]
        )
      end
    end
end
