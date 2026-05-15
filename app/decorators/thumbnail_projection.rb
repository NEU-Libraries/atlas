# frozen_string_literal: true

# Computes the thumbnail URI for a resource by traversing its
# `:derivative` FileSet and finding the Delegate with role
# `thumbnail_image`. Returns nil when either is absent — surfacing
# `null` to clients that previously read the flat `Resource#thumbnail`
# field.
module ThumbnailProjection
  def thumbnail_uri
    fs = children.find { |c| c.is_a?(FileSet) && c.type == Classification.derivative.name }
    return nil unless fs

    delegate = Atlas.query.find_members(resource: fs).find do |m|
      m.is_a?(Delegate) && m.use == Role.thumbnail_image.name
    end
    delegate&.uri
  end
end
