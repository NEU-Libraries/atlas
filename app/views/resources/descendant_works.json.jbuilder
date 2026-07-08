# frozen_string_literal: true

# The flattened subtree as Work digests — same vocabulary as
# resources/find_many and compilations/contents, so a consumer parses one shape
# across all three. Tombstoned works are filtered out by the query, so no flag
# is carried here.
json.works @works do |digest|
  json.id digest[:noid]
  json.noid digest[:noid]
  json.klass digest[:klass]
  json.title digest[:title]
  json.thumbnail digest[:thumbnail]
end
json.pagination @pagination
