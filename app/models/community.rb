# frozen_string_literal: true

class Community < Resource
  # One structural parent, or nil for a top-of-tree Community. Scalar and
  # .optional — a plain Valkyrie::Types::ID coerces an explicit nil to an
  # empty ID(""), but a top-level Community must hold a genuine nil (no parent
  # edge, no a_member_of_tesim projection).
  attribute :a_member_of, Valkyrie::Types::ID.optional
  attribute :type, Valkyrie::Types::String.default(Classification.community.name.freeze)

  # Marks an Atlas auto-provisioned structural container — the singleton "People"
  # Community that parents every Person's personal root (minted by
  # PersonalRootCreator). Not discoverable content: Cerberus excludes it from the
  # global catalog. The Community-level sibling of Collection#personal_root; set
  # at find-or-create and projected to system_container_bsi for discovery (mirrors
  # `personal_root`), not MODS.
  attribute :system_container, Valkyrie::Types::Bool.default(false)
end
