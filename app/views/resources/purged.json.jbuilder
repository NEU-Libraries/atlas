# frozen_string_literal: true

# No title or other metadata: a purge is taken because the record itself must
# go. No `error` key either, because atlas_rb raises on a 410 whose error is
# `tombstoned` and must return this body instead.
json.set! @root do
  json.id @purged.noid
  json.purged true
  json.purged_at @purged.purged_at.iso8601
end
