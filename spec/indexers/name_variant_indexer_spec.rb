# frozen_string_literal: true

require 'rails_helper'

RSpec.describe NameVariantIndexer do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  def work_with_mods(names: [], subject_headings: [])
    mods = Metadata::MODS.new(
      names:            names.map { |attrs| Metadata::Fields::Name.new(**attrs) },
      subject_headings: subject_headings.map { |attrs| Metadata::Fields::SubjectHeading.new(**attrs) }
    )
    Work.new.tap { |w| allow(w).to receive(:mods).and_return(mods) }
  end

  def topic(text) = { parts: [text], heading: text, axis: 'topic' }

  def variants_for(resource) = described_class.new(resource: resource).to_solr[:name_variant_teim]

  describe '#to_solr' do
    it 'returns an empty hash for a resource with no access copy' do
      aggregate_failures do
        expect(described_class.new(resource: Blob.new).to_solr).to eq({})
        expect(described_class.new(resource: FileSet.new).to_solr).to eq({})
      end
    end

    it 'expands a mods:name, whatever its role' do
      resource = work_with_mods(names: [{ name: 'Smith, Timothy', roles: ['Contributor'] }])

      expect(variants_for(resource)).to contain_exactly('Tim Smith', 'Timmy Smith')
    end

    it 'expands a name-shaped topic' do
      resource = work_with_mods(subject_headings: [topic('Nick Myers')])

      expect(variants_for(resource)).to include('Nicholas Myers')
    end

    it 'expands a personal name subject from its first part' do
      parts = ['Lincoln, Abraham, 1809-1865', 'Assassination']
      heading = { parts: parts, heading: parts.join(' -- '), axis: 'personal_name' }
      resource = work_with_mods(subject_headings: [heading])

      expect(variants_for(resource)).to include('Abe Lincoln')
    end

    # Topics are free text, so the shape rule and the table both have to pass.
    # Each of these is a topic from a real IPTC record.
    it 'leaves topics alone that are not names' do
      resource = work_with_mods(subject_headings: [
                                  topic('Northeastern Alumni'), topic('Phoenix Tailings'),
                                  topic('NU entrepreneurs'), topic('Co-Founder and CEO of Phoenix Tailings')
                                ])

      expect(described_class.new(resource: resource).to_solr).to eq({})
    end

    it 'skips a topic heading with subdivisions' do
      resource = work_with_mods(subject_headings: [
                                  { parts: ['Nick Myers', 'Portraits'], heading: 'Nick Myers -- Portraits', axis: 'topic' }
                                ])

      expect(described_class.new(resource: resource).to_solr).to eq({})
    end
  end

  describe 'end to end' do
    let(:mods_xml) do
      <<~XML
        <mods:mods xmlns:mods="http://www.loc.gov/mods/v3">
          <mods:titleInfo usage="primary"><mods:title>Entrepreneurs</mods:title></mods:titleInfo>
          <mods:name type="personal"><mods:namePart type="given">Timothy</mods:namePart><mods:namePart type="family">Stone</mods:namePart><mods:role><mods:roleTerm type="text">University Photographer</mods:roleTerm></mods:role></mods:name>
          <mods:subject><mods:topic>Northeastern Alumni</mods:topic></mods:subject>
          <mods:subject><mods:topic>Nick Myers</mods:topic></mods:subject>
        </mods:mods>
      XML
    end

    def matches?(query)
      Atlas.index_adapter.connection.get(
        'select', params: { q: query, fq: %(id:"#{work.id}"), fl: 'id' }
      ).dig('response', 'numFound') == 1
    end

    it 'lets a formal name find a diminutive topic, and a diminutive find a formal mods:name' do
      work.mods_xml = mods_xml
      Atlas.persister.save(resource: Work.find(work.noid))

      aggregate_failures do
        expect(matches?('name_variant_teim:"Nicholas Myers"')).to be(true)
        expect(matches?('name_variant_teim:"Tim Stone"')).to be(true)
        expect(matches?('name_variant_teim:Northeastern')).to be(false)
      end
    end
  end
end
