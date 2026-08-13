# frozen_string_literal: true

# Emits the on-disk preservation envelope (relationships.json /
# properties.json + permissions.json) into each resource's own NOID-keyed
# OCFL object. Bus-factor: a librarian with disk access alone can rebuild
# the resource graph and ACLs without Atlas, Postgres, or Solr.
module Preservable
  extend ActiveSupport::Concern

  # v1 → v2: :depositor changed from "array of edit_users" to a single
  # NUID string (intellectual owner). Added :proxy_uploader (single NUID
  # string) and :edit_users (the explicit ACL list, which in v1 was carried
  # under :depositor).
  # v2 → v3: additive :position — FileSet page order within a multipage
  # Work; null elsewhere. The Work-level METS structMap is the canonical
  # preservation record of order; this keeps each FileSet's own OCFL
  # object self-describing in isolation.
  # v3 → v4: additive :associations — the typed Work-to-Work edges
  # (is_codebook_for and its four siblings), keyed by predicate and empty on
  # every other resource class. Each edge is a human judgement about two
  # objects that nothing else in the repository records and no job can derive
  # again, so it has to survive on disk. Note a_linked_member_of is
  # deliberately absent: a linked membership is a discovery convenience a Set
  # recipe can express again, not an assertion that exists nowhere else.
  ENVELOPE_SCHEMA_VERSION = 4

  def graph_payload
    {
      schema_version: ENVELOPE_SCHEMA_VERSION,
      noid:           noid,
      type:           self.class.name,
      classification: respond_to?(:type) ? type : nil,
      position:       respond_to?(:position) ? position : nil,
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
