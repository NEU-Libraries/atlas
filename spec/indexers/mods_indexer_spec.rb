# frozen_string_literal: true

require 'rails_helper'

# Covers the operational-flag half of MODSIndexer. The MODS projections
# (title / description / permanent_url) are exercised through the request and
# decorator specs; these are the flags a search result row reads directly,
# where an unindexed field means the pill cannot render at all.
RSpec.describe MODSIndexer do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  after { Atlas.persister.wipe! }

  def flag_fields_in_solr(resource)
    Atlas.index_adapter.connection.get(
      'select', params: { q: %(id:"#{resource.id}"), fl: 'in_progress_bsi,incomplete_bsi,incomplete_reason_ssi' }
    ).dig('response', 'docs').first
  end

  describe '#to_solr' do
    it 'projects both lifecycle flags on a fresh Work, with a null reason' do
      fields = described_class.new(resource: work).to_solr

      expect(fields[:in_progress_bsi]).to        be true
      expect(fields[:incomplete_bsi]).to         be false
      expect(fields[:incomplete_reason_ssi]).to  be_nil
    end

    it 'projects the reason token once the Work is flagged' do
      work.incomplete        = true
      work.incomplete_reason = 'pdf_rendition_gave_up'

      fields = described_class.new(resource: work).to_solr

      expect(fields[:incomplete_bsi]).to        be true
      expect(fields[:incomplete_reason_ssi]).to eq('pdf_rendition_gave_up')
    end

    it 'omits the pair on resources that do not carry it' do
      expect(described_class.new(resource: Blob.new).to_solr).not_to have_key(:incomplete_bsi)
      expect(described_class.new(resource: FileSet.new).to_solr).not_to have_key(:incomplete_bsi)
    end
  end

  describe 'end-to-end through the composite indexer' do
    it 'lands the flag and its reason on the Work doc' do
      work.incomplete        = true
      work.incomplete_reason = 'media_rendition_gave_up'
      Atlas.persister.save(resource: work)

      doc = flag_fields_in_solr(work)
      expect(doc['incomplete_bsi']).to        be true
      expect(doc['incomplete_reason_ssi']).to eq('media_rendition_gave_up')
    end

    it 'clears both fields from the doc when the Work is repaired' do
      work.incomplete        = true
      work.incomplete_reason = 'ingest_gave_up'
      Atlas.persister.save(resource: work)

      repaired = Work.find(work.noid)
      repaired.incomplete        = false
      repaired.incomplete_reason = nil
      Atlas.persister.save(resource: repaired)

      doc = flag_fields_in_solr(work)
      expect(doc['incomplete_bsi']).to be false
      expect(doc).not_to have_key('incomplete_reason_ssi')
    end
  end
end
