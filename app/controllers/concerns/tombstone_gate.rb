# frozen_string_literal: true

# Withholds the bytes and the file lists of a tombstoned resource from every
# caller without :read_tombstoned. The operator tiers keep them, because they
# review a removed file before they restore it. See docs/resource-graph.md.
module TombstoneGate
  extend ActiveSupport::Concern

  private

    # Call after the :read check and the nil check, so a caller who may not read
    # the resource learns nothing about its tombstone.
    def refuse_tombstoned!(resource)
      source = resource.tombstone_source
      return if source.nil? || can?(:read_tombstoned, resource)

      raise Exceptions::Tombstoned, source
    end
end
