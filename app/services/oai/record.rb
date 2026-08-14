# frozen_string_literal: true

module OAI
  # One record in a ListRecords / ListIdentifiers / GetRecord response,
  # assembled from a Solr document plus the two things a Solr document cannot
  # supply: the published Sets the Work belongs to, and — for oai_dc only —
  # the JSON MODS row the crosswalk reads.
  #
  # Both extras are batched per page by .build, so a fifty-record page costs a
  # fixed handful of queries rather than a hundred. The MODS XML itself needs
  # no extra work at all: OAIIndexer already parked the whole document on the
  # Solr doc.
  class Record
    attr_reader :noid, :set_specs, :dublin_core

    # `metadata_prefix` nil builds header-only records (ListIdentifiers).
    def self.build(docs, metadata_prefix: nil)
      noids       = docs.map { |doc| noid_of(doc) }
      sets        = OAISetMembershipQuery.call(noids: noids)
      mods_rows   = metadata_prefix == 'oai_dc' ? json_mods_rows(noids) : {}

      docs.map do |doc|
        noid = noid_of(doc)
        row  = mods_rows[noid]
        new(doc: doc, noid: noid, set_specs: sets.fetch(noid, []),
            dublin_core: row && DublinCore.call(row))
      end
    end

    def self.noid_of(doc)
      Array(doc['alternate_ids_ssim']).first.to_s.delete_prefix('id-')
    end

    # The access copy is keyed by NOID (Modsable writes valkyrie_id: noid), so
    # one query covers the page.
    def self.json_mods_rows(noids)
      Metadata::MODS.where(valkyrie_id: noids).index_by(&:valkyrie_id)
    end
    private_class_method :json_mods_rows

    def initialize(doc:, noid:, set_specs:, dublin_core: nil)
      @doc         = doc
      @noid        = noid
      @set_specs   = set_specs
      @dublin_core = dublin_core
    end

    def identifier
      OAI.identifier_for(noid)
    end

    # Normalized to the granularity Identify advertises. Solr may hand back
    # fractional seconds; a harvester comparing datestamps to its own `from`
    # must not have to cope with two shapes.
    def datestamp
      value = @doc['oai_datestamp_dtsi']
      value.present? ? Time.parse(value).utc.iso8601 : nil
    end

    # A withdrawn Work keeps its Solr document and its public ACL, so it can
    # be reported. A purged one leaves nothing behind, which is why the
    # repository declares deletedRecord as transient.
    def deleted?
      ActiveModel::Type::Boolean.new.cast(@doc['tombstoned_bsi']).present?
    end

    # The preservation MODS, verbatim, minus its XML declaration — an
    # embedded document cannot carry one. Nil for a record whose Work predates
    # the OAIIndexer backfill.
    def mods_xml
      raw = @doc['mods_xml_ss']
      raw.presence&.sub(/\A<\?xml[^>]*\?>\s*/, '')
    end
  end
end
