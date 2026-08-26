# frozen_string_literal: true

# Seeds the `mods` memo on a collection of Modsable resources from one
# metadata_mods read, so rendering a page of rows costs a single query instead
# of one per row.
#
# The access copy is keyed by NOID (Metadata::MODS#valkyrie_id holds the NOID,
# not the Valkyrie id — see Modsable#mods), so the batch is a plain `where` on
# that column. A resource the batch finds no row for is seeded with nil, which
# is the same answer `Modsable#mods` would reach on its own; without seeding it
# the row would fall back to a per-row query and undo the batch.
#
# Read-path only. Nothing invalidates the memo, so never call this on a request
# that goes on to write MODS.
class MODSPreloader < ApplicationService
  def self.call(resources:)
    new(resources: resources).call
  end

  def initialize(resources:)
    @resources = Array(resources)
  end

  def call
    modsable = @resources.select { |r| r.respond_to?(:preload_mods) }
    return @resources if modsable.empty?

    rows = Metadata::MODS.where(valkyrie_id: modsable.map(&:noid)).index_by(&:valkyrie_id)
    modsable.each { |resource| resource.preload_mods(rows[resource.noid]) }
    @resources
  end
end
