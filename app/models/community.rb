# frozen_string_literal: true

class Community < Resource
  # One structural parent, or nil for a top-of-tree Community. Scalar and
  # .optional — a plain Valkyrie::Types::ID coerces an explicit nil to an
  # empty ID(""), but a top-level Community must hold a genuine nil (no parent
  # edge, no a_member_of_tesim projection).
  attribute :a_member_of, Valkyrie::Types::ID.optional
  attribute :type, Valkyrie::Types::String.default(Classification.community.name.freeze)
end
