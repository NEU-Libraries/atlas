# frozen_string_literal: true

# Every child of a Community or Collection, live or withdrawn, for inspecting
# the graph from an API client. The typed /children routes answer 410 for a
# tombstoned container; this one does not. Admins and delegated admins only.
# See docs/resource-graph.md.
class ResourceChildrenController < ApplicationController
  include IndexReadGate

  CONTAINERS = [Community, Collection].freeze

  def show
    resource = Resource.find(params.expect(:id))
    authorize_index_read!(resource)
    return head(:not_found) unless CONTAINERS.include?(resource.class)

    # The digest's title and thumbnail are a read each without the preloads.
    @resources = readable(resource.filtered_child_resources).map(&:decorate)
    MODSPreloader.call(resources: @resources)
    ThumbnailPreloader.call(resources: @resources)
    render 'resources/find_many'
  end
end
