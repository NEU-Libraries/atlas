# frozen_string_literal: true

# A tombstone withholds everything about the resource below the operator tiers:
# its bytes, its files, its metadata and most of its record. The operator tiers
# keep it all, because they review a removal before they restore it. See
# docs/resource-graph.md.
module TombstoneGate
  extend ActiveSupport::Concern

  private

    # Call each of these after the :read check and the nil check, so a caller
    # who may not read the resource learns nothing about its tombstone.
    def tombstone_withheld?(resource)
      resource.tombstone_source.present? && !can?(:read_tombstoned, resource)
    end

    def refuse_tombstoned!(resource)
      raise Exceptions::Tombstoned, resource.tombstone_source if tombstone_withheld?(resource)
    end

    # The removal page's record: enough to say what was removed and why, and
    # nothing a crawler could keep indexing. Call it before any cached_render,
    # because the cached 410 is the operators' full record.
    def render_tombstone_stub(resource, root:)
      @resource = resource.decorate
      @root = root
      render 'resources/tombstone', status: :gone
    end
end
