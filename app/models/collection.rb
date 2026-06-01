# frozen_string_literal: true

class Collection < Resource
  # One structural parent (Community or Collection). Scalar — see Work.
  attribute :a_member_of, Valkyrie::Types::ID
  attribute :type, Valkyrie::Types::String.default(Classification.collection.name.freeze)
end
