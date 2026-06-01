# frozen_string_literal: true

class Community < Resource
  # One structural parent, or nil for a top-of-tree Community. Scalar.
  attribute :a_member_of, Valkyrie::Types::ID
  attribute :type, Valkyrie::Types::String.default(Classification.community.name.freeze)
end
