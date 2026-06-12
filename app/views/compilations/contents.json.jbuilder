# frozen_string_literal: true

# Lightweight digests, same vocabulary as resources/find_many — CERES and
# any future consumer parse one shape for both. Tombstoned works are
# filtered out by the query, so no flag is carried here.
json.contents @contents do |digest|
  json.id digest[:noid]
  json.noid digest[:noid]
  json.klass digest[:klass]
  json.title digest[:title]
  json.thumbnail digest[:thumbnail]
end
json.pagination @pagination
