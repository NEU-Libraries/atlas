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

  ENVELOPE_SCHEMA_VERSION = 5

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
      associations:   association_noids
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

    def parent_noids
      ids = Array(respond_to?(:a_member_of) ? a_member_of : []).compact
      return [] if ids.empty?

      Atlas.query.find_many_by_ids(ids: ids).map(&:noid)
    end

    def member_noids
      ids = Array(respond_to?(:member_ids) ? member_ids : []).compact
      return [] if ids.empty?

      Atlas.query.find_many_by_ids(ids: ids).map(&:noid)
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

        result[predicate.to_s] = Atlas.query.find_many_by_ids(ids: ids).map(&:noid)
      end
    end
end
