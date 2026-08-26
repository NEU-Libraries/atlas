# frozen_string_literal: true

# Seeds the `children` memo on a set of resources from one batched containment
# read (FindManyMembers), so a render over a set costs two queries rather than
# two per resource.
#
# Returns the flattened children, so a caller that needs a second level (the
# thumbnail projection, a Work's assets) can pass them straight back in.
#
# Read-path only — see Relationships#preload_children for why this is opt-in
# rather than a memo on `children` itself.
class ChildrenPreloader < ApplicationService
  def self.call(resources:)
    new(resources: resources).call
  end

  def initialize(resources:)
    @resources = Array(resources)
  end

  def call
    seedable = @resources.select { |r| r.respond_to?(:preload_children) && r.id.present? }
    return [] if seedable.empty?

    grouped = Atlas.query.custom_queries.find_many_members(resources: seedable)
    seedable.each { |resource| resource.preload_children(grouped.fetch(resource.id.to_s, [])) }
    seedable.flat_map(&:children)
  end
end
