# frozen_string_literal: true

require 'rails_helper'

# The citation rules a client keys on: which CSL type a record reads as, and
# how precisely its date is stated. GET /works/{id}/citation serves them, and
# CitationIndexer indexes the same creators and year. See docs/citation.md.
RSpec.describe Citation do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }

  def citation_for(inner)
    work = WorkCreator.call(parent_id: collection.noid)
    Work.find(work.noid).mods_xml = <<~XML
      <mods:mods xmlns:mods="http://www.loc.gov/mods/v3">
        <mods:titleInfo usage="primary"><mods:title>A record</mods:title></mods:titleInfo>
        #{inner}
      </mods:mods>
    XML
    described_class.new(Work.find(work.noid))
  end

  describe '#csl_type' do
    it 'takes a genre that names a CSL type before the type of resource' do
      citation = citation_for('<mods:genre>Technical reports</mods:genre><mods:typeOfResource>text</mods:typeOfResource>')
      expect(citation.csl_type).to eq('report')
    end

    it 'falls back to the type of resource' do
      expect(citation_for('<mods:typeOfResource>still image</mods:typeOfResource>').csl_type).to eq('graphic')
    end

    it 'is a document when neither names a type' do
      expect(citation_for('<mods:genre>podcasts</mods:genre>').csl_type).to eq('document')
    end
  end

  describe '#issued' do
    it 'gives the year alone for a year-precision date' do
      citation = citation_for('<mods:originInfo><mods:dateCreated encoding="w3cdtf">1972</mods:dateCreated></mods:originInfo>')
      expect(citation.issued).to eq('date-parts' => [[1972]])
      expect(citation.year).to eq('1972')
    end

    it 'gives the record\'s own words for a date it could not encode' do
      citation = citation_for('<mods:originInfo><mods:dateCreated>Spring term, 1950s</mods:dateCreated></mods:originInfo>')
      expect(citation.issued).to eq('literal' => 'Spring term, 1950s')
    end

    it 'is nil when the record gives no date' do
      expect(citation_for('').issued).to be_nil
    end
  end
end
