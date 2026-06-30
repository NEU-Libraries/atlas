# frozen_string_literal: true

class Collection < Resource
  # One structural parent (Community or Collection). Scalar — see Work.
  attribute :a_member_of, Valkyrie::Types::ID
  attribute :type, Valkyrie::Types::String.default(Classification.collection.name.freeze)

  # Marks a genre-showcase Collection (Research Publications, Datasets, ...)
  # that a Community opts into, so Cerberus can render it as a "Featured"-badged
  # entry in the community's browse. A discovery/badge hint, not bibliographic
  # description — hence a resource attribute projected to featured_bsi, not MODS.
  attribute :featured, Valkyrie::Types::Bool.default(false)

  # Marks a Person's personal-root Collection (minted by PersonalRootCreator at
  # Person.create). A structural container, not content: Cerberus excludes it
  # from the global catalog and rewrites breadcrumbs around it. Set once at mint
  # time; projected to personal_root_bsi for discovery (mirrors `featured`), not
  # MODS.
  attribute :personal_root, Valkyrie::Types::Bool.default(false)
end
