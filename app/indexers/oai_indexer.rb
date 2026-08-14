# frozen_string_literal: true

# Projects the two fields the OAI-PMH provider (/oai) reads off a Work's Solr
# doc, so a ListRecords page is one Solr query with no file reads and no
# Nokogiri parses on the request path.
#
#   mods_xml_ss        <- the full MODS XML (the preservation copy, verbatim)
#   oai_datestamp_dtsi <- resource.updated_at, the harvest datestamp
#
# `*_ss` is a stored-only, non-indexed, single-valued string, so a multi-KB
# document costs the index nothing. The cost lands on the write path — one
# OCFL read and one parse per Work save — which is the side of the trade this
# project deliberately pays (see the MODS dual-representation note in
# CLAUDE.md).
#
# The datestamp is `resource.updated_at`, NOT Valkyrie's `updated_at_dtsi`.
# Valkyrie's Solr ModelConverter sets that field to `Time.current` at index
# time, so every reindex would rewrite it and force harvesters to re-fetch the
# whole repository. `updated_at` comes off the Postgres row: a real edit moves
# it (Atlas.persister writes both stores), and a Solr-only reindex
# (Atlas.index_adapter, which POST /resources/:id/reindex uses) leaves it
# alone.
#
# Work-only: an OAI record is a Work, and gating here keeps the extra read off
# every container save.
class OAIIndexer
  attr_reader :resource

  def initialize(resource:)
    @resource = resource
  end

  def to_solr
    return {} unless resource.is_a?(Work)

    fields = {}
    fields[:oai_datestamp_dtsi] = resource.updated_at.utc.iso8601 if resource.updated_at
    fields[:mods_xml_ss]        = mods_xml if mods_xml.present?
    fields
  end

  private

    # Modsable#mods_xml re-reads the OCFL blob on every call, so hold it.
    def mods_xml
      return @mods_xml if defined?(@mods_xml)

      @mods_xml = resource.mods_xml
    end
end
