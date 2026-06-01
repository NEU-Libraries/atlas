# frozen_string_literal: true

class Work < Resource
  # The one structural home (Tree). Scalar — a Work lives in exactly one
  # Collection. Mirrors FileSet's existing scalar a_member_of.
  attribute :a_member_of, Valkyrie::Types::ID
  # The many discovery links (DAG overlay). A Work can be a "linked member"
  # of additional Collections without duplicating the object. Leaves-only:
  # only Works carry this; the collection/community backbone stays a strict
  # tree, so cycles are structurally impossible. Adds placement, never
  # permission — the Work keeps its single ACL.
  attribute :a_linked_member_of, Valkyrie::Types::Set.of(Valkyrie::Types::ID)
  attribute :type, Valkyrie::Types::String.default(Classification.work.name.freeze)

  # Operator-visibility flag: Cerberus's bulk-deposit jobs leave this true
  # until they've confirmed all expected children are deposited, then flip
  # it to false via POST /works/:id/complete. Indexed in Solr so the
  # /works?in_progress=true monitoring query can find stuck deposits.
  attribute :in_progress, Valkyrie::Types::Bool.default(true)
end
