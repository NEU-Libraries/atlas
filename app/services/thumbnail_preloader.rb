# frozen_string_literal: true

# Seeds the sized-image projection on a set of decorated resources in three
# queries, instead of the three per resource ThumbnailProjection costs on its
# own (two to find the resource's children, one for the derivative FileSet's
# members).
#
# Two batched levels: the resources' children, then the members of the
# :derivative FileSets found among them. Takes decorated resources — the
# projection and its preload seam live on the decorator, so an undecorated
# resource is skipped.
class ThumbnailPreloader < ApplicationService
  def self.call(resources:)
    new(resources: resources).call
  end

  def initialize(resources:)
    @resources = Array(resources)
  end

  def call
    projecting = @resources.select { |r| r.respond_to?(:preload_derivative_members) }
    return @resources if projecting.empty?

    ChildrenPreloader.call(resources: projecting)
    seed_tiers(projecting, derivative_members_by_file_set(projecting))
    @resources
  end

  private

    def derivative_members_by_file_set(projecting)
      file_sets = projecting.filter_map(&:derivative_member_file_set)
      return {} if file_sets.empty?

      Atlas.query.custom_queries.find_many_ordered_members(resources: file_sets)
    end

    def seed_tiers(projecting, members)
      projecting.each do |resource|
        file_set = resource.derivative_member_file_set
        resource.preload_derivative_members(file_set ? members.fetch(file_set.id.to_s, []) : [])
      end
    end
end
