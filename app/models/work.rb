# frozen_string_literal: true

class Work < Resource
  attribute :a_member_of, Valkyrie::Types::Set.of(Valkyrie::Types::ID).meta(ordered: true)
  attribute :type, Valkyrie::Types::String.default(Classification.work.name.freeze)

  # Operator-visibility flag: Cerberus's bulk-deposit jobs leave this true
  # until they've confirmed all expected children are deposited, then flip
  # it to false via POST /works/:id/complete. Indexed in Solr so the
  # /works?in_progress=true monitoring query can find stuck deposits.
  attribute :in_progress, Valkyrie::Types::Bool.default(true)
end
