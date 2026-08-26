# frozen_string_literal: true

# The downloadable assets of many page FileSets at once — the read behind
# GET /works/:id/file_sets.
#
# A page's assets are its own member Blobs plus the members of any nested
# :derivative FileSet (per-page IIIF Delegates land there via
# DelegateCreator(resource_id: <page FileSet>)). The page's METS Blob is
# excluded by Role.downloadable?.
#
# That is two levels of containment, so resolving it per page cost two queries
# per page — a book-length Work paid hundreds. Here each level is one batched
# read (FindManyMembers), so the cost is fixed at two regardless of page count.
# Member order is preserved within each level, because page order and asset
# order both come off member_ids.
class PageAssetsQuery
  def self.call(file_sets:)
    new(file_sets: file_sets).call
  end

  def initialize(file_sets:)
    @file_sets = Array(file_sets)
  end

  # @return [Hash{String => Array<Valkyrie::Resource>}] page FileSet Valkyrie
  #   id (as a string) => its downloadable assets.
  def call
    return {} if @file_sets.empty?

    # Level one is the union (the batched `children`), matching what the
    # unbatched read did; level two is member_ids only, matching find_members.
    direct = union_members(@file_sets)
    nested = ordered_members(direct.values.flatten.select { |m| m.is_a?(FileSet) })

    @file_sets.each_with_object({}) do |file_set, assets|
      members = direct.fetch(file_set.id.to_s, []).flat_map do |member|
        member.is_a?(FileSet) ? nested.fetch(member.id.to_s, []) : [member]
      end
      assets[file_set.id.to_s] = members.select { |m| Role.downloadable?(m.use) }
    end
  end

  private

    def union_members(resources)
      return {} if resources.empty?

      Atlas.query.custom_queries.find_many_members(resources: resources)
    end

    def ordered_members(resources)
      return {} if resources.empty?

      Atlas.query.custom_queries.find_many_ordered_members(resources: resources)
    end
end
