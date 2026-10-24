# frozen_string_literal: true

# Emits the on-disk preservation envelope (relationships.json,
# properties.json, permissions.json) into each resource's own NOID-keyed OCFL
# object. Bus-factor: a librarian with disk access alone can rebuild the
# resource graph and the ACLs without Atlas, Postgres or Solr.
#
# docs/resource-graph.md records what each schema bump added and why. Two
# absences are deliberate: a_linked_member_of, which a Set recipe can express
# again, and the fungible derived fields (full_text, derivative_permissions).
module Preservable
  extend ActiveSupport::Concern

  ENVELOPE_SCHEMA_VERSION = 7

  def graph_payload
    {
      schema_version: ENVELOPE_SCHEMA_VERSION,
      noid:           noid,
      type:           self.class.name,
      classification: respond_to?(:type) ? type : nil,
      position:       respond_to?(:position) ? position : nil,
      handle:         respond_to?(:handle) ? handle : nil,
      a_member_of:    parent_noids,
      member_ids:     member_noids,
      associations:   association_noids,
      tombstone:      tombstone_payload
    }
  end

  def graph_filename
    'relationships.json'
  end

  def permissions_payload
    permissions.merge(schema_version: ENVELOPE_SCHEMA_VERSION, noid: noid)
  end

  def write_preservation_envelope!
    PreservationEnvelopeWriter.call(resource: self)
  end

  private

    # A withdrawal and its policy note are a human decision that nothing else
    # records, so a rebuild from disk must not bring the resource back as live.
    def tombstone_payload
      return nil unless tombstoned

      { at: tombstoned_at&.iso8601, by: tombstoned_by, reason: tombstone_reason }
    end

    def parent_noids
      noids_in_order(Array(respond_to?(:a_member_of) ? a_member_of : []))
    end

    def member_noids
      noids_in_order(Array(respond_to?(:member_ids) ? member_ids : []))
    end

    # find_many_by_ids answers in database order, so the envelope would list the
    # same members in whatever order Postgres returned them, and an unchanged
    # payload would cut a new OCFL version. An id that resolves to nothing drops.
    def noids_in_order(ids)
      ids = ids.compact
      return [] if ids.empty?

      found = Atlas.query.find_many_by_ids(ids: ids).index_by { |resource| resource.id.to_s }
      ids.filter_map { |id| found[id.to_s]&.noid }
    end

    # Only the OUTBOUND edges, because only they are stored here. The other
    # end reads back from the asserting Work's own envelope, so a
    # reconstitution pass over the whole store recovers both directions
    # without either file having to be kept in step with the other.
    def association_noids
      return {} unless is_a?(Work)

      Work::ASSOCIATION_TYPES.each_with_object({}) do |predicate, result|
        ids = Array(self[predicate]).compact
        next if ids.empty?

        result[predicate.to_s] = noids_in_order(ids)
      end
    end
end
