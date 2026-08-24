# frozen_string_literal: true

# The bare FileSet keys. The wrapped show/create/update payload and the flat
# rows of the index both render this, so the two shapes cannot drift.
json.id file_set.noid
json.type file_set.type
json.position file_set.position
json.tombstoned file_set.tombstoned
json.tombstoned_at file_set.tombstoned_at&.to_s
json.tombstoned_by file_set.tombstoned_by
