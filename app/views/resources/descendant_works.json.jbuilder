# frozen_string_literal: true

# The flattened subtree as Work digests — find_many's vocabulary plus the
# citation facts a search row carries, the same shape as compilations/contents.
# Tombstoned works are filtered out by the query, so no flag is carried here.
json.works @works do |digest|
  json.id digest[:noid]
  json.noid digest[:noid]
  json.klass digest[:klass]
  json.title digest[:title]
  json.thumbnail digest[:thumbnail]
  json.creators digest[:creators]
  json.year digest[:year]
  json.embargoed digest[:embargoed]
end
json.pagination @pagination
