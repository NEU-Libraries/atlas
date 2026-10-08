# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DarwinCoreIndexer do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }
  let(:dwc_xml)    { Rails.root.join('spec/fixtures/files/dwc.xml').read }

  let(:fields) do
    %w[dwc_scientific_name_tesim dwc_scientific_name_ssim dwc_country_ssim dwc_event_date_dtsi dwc_coordinates_llsi]
  end

  after { Atlas.persister.wipe! }

  def solr_doc(resource)
    Atlas.index_adapter.connection.get(
      'select', params: { q: %(id:"#{resource.id}"), fl: fields.join(',') }
    ).dig('response', 'docs').first
  end

  # The indexer reads json_attributes only, so a bare row stands in for a
  # record without an OCFL write.
  def indexed(terms)
    Metadata::DarwinCore.create!(valkyrie_id: work.noid, json_attributes: terms)
    described_class.new(resource: Work.find(work.id)).to_solr
  end

  describe '#to_solr' do
    it 'projects the four terms from the fixture record' do
      work.darwin_core_xml = dwc_xml

      expect(described_class.new(resource: Work.find(work.id)).to_solr).to eq(
        dwc_scientific_name_tesim: 'Perognathus inornatus inornatus',
        dwc_scientific_name_ssim:  'Perognathus inornatus inornatus',
        dwc_country_ssim:          'United States',
        dwc_event_date_dtsi:       '1911-05-14T00:00:00Z',
        dwc_coordinates_llsi:      '35.45038,-118.9092'
      )
    end

    it 'returns an empty hash for a Work with no record, and for other types' do
      expect(described_class.new(resource: work).to_solr).to eq({})
      expect(described_class.new(resource: collection).to_solr).to eq({})
      expect(described_class.new(resource: FileSet.new).to_solr).to eq({})
    end

    it 'indexes a partial date or a range by its start' do
      expect(indexed('eventDate' => '1906-06')[:dwc_event_date_dtsi]).to eq('1906-06-01T00:00:00Z')
      Metadata::DarwinCore.delete_all
      expect(indexed('eventDate' => '1900/1909')[:dwc_event_date_dtsi]).to eq('1900-01-01T00:00:00Z')
      Metadata::DarwinCore.delete_all
      expect(indexed('eventDate' => '1963-03-08T14:07-0600')[:dwc_event_date_dtsi]).to eq('1963-03-08T20:07:00Z')
    end

    it 'leaves out a date or a point that does not parse, and keeps the rest' do
      result = indexed('scientificName' => 'Abarenicola sp.', 'eventDate' => 'spring 1911',
                       'decimalLatitude' => '95', 'decimalLongitude' => '-118.9')

      expect(result).to eq(dwc_scientific_name_tesim: 'Abarenicola sp.', dwc_scientific_name_ssim: 'Abarenicola sp.')
    end

    it 'leaves out a point with only one half' do
      expect(indexed('decimalLatitude' => '35.4')).to eq({})
    end
  end

  # A record write saves no Work, so the concern re-projects the Solr doc
  # itself; without that, the fields would wait for the next unrelated save.
  describe 'the Solr doc' do
    it 'gains the fields on a write and loses them on a withdrawal' do
      work.darwin_core_xml = dwc_xml
      expect(solr_doc(work)).to include('dwc_country_ssim'     => ['United States'],
                                        'dwc_coordinates_llsi' => '35.45038,-118.9092')

      Work.find(work.id).withdraw_darwin_core!(by: '000000004')
      expect(solr_doc(work).keys & fields).to be_empty
    end
  end
end
