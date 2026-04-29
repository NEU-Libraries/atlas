# frozen_string_literal: true

# Emits the on-disk preservation envelope (relationships.json /
# properties.json + permissions.json) into each resource's own NOID-keyed
# OCFL object. Bus-factor: a librarian with disk access alone can rebuild
# the resource graph and ACLs without Atlas, Postgres, or Solr.
module Preservable
  extend ActiveSupport::Concern

  ENVELOPE_SCHEMA_VERSION = 1

  def graph_payload
    {
      schema_version: ENVELOPE_SCHEMA_VERSION,
      noid: noid,
      type: self.class.name,
      classification: respond_to?(:type) ? type : nil,
      a_member_of: parent_noids,
      member_ids: member_noids
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
end
