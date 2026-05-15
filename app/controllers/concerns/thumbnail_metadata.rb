# frozen_string_literal: true

# Maps `metadata[<key>]` PATCH parameters from
# Work/Collection/Community update calls to thumbnail-family Delegates
# via DelegateUpdater (one upsert per known key with a non-blank value).
#
# Centralized so the three resource controllers share one definition of
# "which keys we accept" and "which Role each maps to" — adding a fourth
# tier later means one change here, not three nearly-identical edits.
module ThumbnailMetadata
  extend ActiveSupport::Concern

  private

    def process_thumbnail_metadata(resource_id:, metadata:)
      {
        'thumbnail'    => Role.thumbnail_image,
        'thumbnail_2x' => Role.thumbnail_image_2x,
        'preview'      => Role.preview_image
      }.each do |key, role|
        next unless metadata[key].present?

        DelegateUpdater.call(
          resource_id: resource_id,
          use:         role.name,
          uri:         metadata[key]
        )
      end
    end
end
