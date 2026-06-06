# frozen_string_literal: true

# Lightweight digest per resolved resource — just what set-resolution callers
# (breadcrumbs, linked-member lists, load-destination pickers) need, not the
# full typed payload. title/thumbnail are only meaningful on the Modsable
# backbone (Community/Collection/Work); FileSet/Blob resolve to null for those
# rather than erroring. The array is unordered and may be shorter than the
# requested id list — callers index by noid.
json.array! @resources do |resource|
  json.id resource.noid
  json.noid resource.noid
  json.klass resource.class.to_s
  json.title(resource.respond_to?(:plain_title) ? resource.plain_title : nil)
  json.thumbnail(resource.respond_to?(:thumbnail_uri) ? resource.thumbnail_uri : nil)
  json.tombstoned resource.tombstoned
end
