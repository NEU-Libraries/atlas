# frozen_string_literal: true

require 'rails_helper'

# Covers the operational-flag half of MODSIndexer plus the match-only title.
# The other MODS projections (description / permanent_url) are exercised through
# the request and decorator specs; the flags are what a search result row reads
# directly, where an unindexed field means the pill cannot render at all.
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

  def title_fields_in_solr(resource)
    Atlas.index_adapter.connection.get(
      'select', params: { q: %(id:"#{resource.id}"), fl: 'title_tsim,title_plain_tsim' }
    ).dig('response', 'docs').first
  end

  # A Work whose #mods returns a controlled access copy, so the projection is
  # asserted directly rather than through the WorkCreator template.
  def work_titled(title)
    mods = Metadata::MODS.new(main_title: Metadata::Fields::TitleInfo.new(title: title))
    Work.new.tap { |w| allow(w).to receive(:mods).and_return(mods) }
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

  describe 'title_plain_tsim' do
    let(:formula) do
      'Origin of the high-energy kink in the superconductor ' \
        'Bi<sub>2</sub>Sr<sub>2</sub>CaCu<sub>2</sub>O<sub>8</sub>'
    end

    it 'projects the markup-free title beside the display title' do
      fields = described_class.new(resource: work_titled(formula)).to_solr

      expect(fields[:title_tsim]).to eq(formula)
      expect(fields[:title_plain_tsim])
        .to eq('Origin of the high-energy kink in the superconductor Bi2Sr2CaCu2O8')
    end

    it 'is absent for a title that carries no markup, so titles are not indexed twice' do
      fields = described_class.new(resource: work_titled('Campus Life')).to_solr

      expect(fields[:title_tsim]).to eq('Campus Life')
      expect(fields).not_to have_key(:title_plain_tsim)
    end

    it 'is absent on a resource that holds no title at all' do
      expect(described_class.new(resource: Blob.new).to_solr).not_to have_key(:title_plain_tsim)
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

    it 'makes the formula a reader types matchable, while the heading keeps its markup' do
      Work.find(work.noid).mods_xml =
        Rails.root.join('spec/fixtures/files/work-enhanced-text-mods.xml').read
      Atlas.persister.save(resource: Work.find(work.noid))

      doc = title_fields_in_solr(work)
      expect(doc['title_tsim'].join).to include('Bi<sub>2</sub>Sr<sub>2</sub>CaCu<sub>2</sub>O<sub>8</sub>')
      expect(doc['title_plain_tsim'].join).to include('Bi2Sr2CaCu2O8')

      # The reader's query. It matched nothing before this field existed,
      # because title_tsim tokenises "sub" and "2" apart from "Bi".
      hits = Atlas.index_adapter.connection.get(
        'select', params: { q: 'title_plain_tsim:"Bi2Sr2CaCu2O8"', fl: 'id' }
      ).dig('response', 'docs')
      expect(hits.pluck('id')).to eq([work.id.to_s])
    end
  end
end
