# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PersonIndexer do
  let(:community) { CommunityCreator.call }
  let(:person)    { PersonCreator.call(nuid: '001234567', display_name: 'Jane Doe') }

  after { Atlas.persister.wipe! }

  def person_doc(resource, *fields)
    Atlas.index_adapter.connection.get(
      'select', params: { q: %(id:"#{resource.id}"), fl: fields.join(',') }
    ).dig('response', 'docs').first
  end

  describe '#to_solr' do
    it 'projects display_name, nuid, and affiliated community NOIDs' do
      person.affiliated_community_ids = [community.id]

      result = described_class.new(resource: person).to_solr
      expect(result[:title_tsim]).to eq(['Jane Doe'])
      expect(result[:type_ssim]).to eq(['Person'])
      expect(result[:noid_ssi]).to eq(person.noid)
      expect(result[:display_name_ssi]).to eq('Jane Doe')
      expect(result[:nuid_ssi]).to eq('001234567')
      expect(result[:affiliated_community_ids_ssim]).to eq([community.noid])
    end

    it 'projects an empty affiliation list when the Person has none' do
      result = described_class.new(resource: person).to_solr
      expect(result[:affiliated_community_ids_ssim]).to eq([])
    end

    it 'returns an empty hash for non-Person resources' do
      expect(described_class.new(resource: community).to_solr).to eq({})
      expect(described_class.new(resource: Work.new).to_solr).to eq({})
      expect(described_class.new(resource: Blob.new).to_solr).to eq({})
    end
  end

  describe 'end-to-end through the composite indexer' do
    it 'lands the projected fields on the Person doc when saved' do
      person.affiliated_community_ids = [community.id]
      saved = Atlas.persister.save(resource: person)

      doc = person_doc(saved, 'title_tsim', 'type_ssim', 'noid_ssi', 'display_name_ssi', 'nuid_ssi',
                       'affiliated_community_ids_ssim', 'internal_resource_tesim')
      # Name in the standard title field → displayed + keyword-searchable.
      expect(doc['title_tsim']).to eq(['Jane Doe'])
      # type_ssim overrides the auto-projected type attribute ("Faculty and
      # Staff") to the facet value 'Person' — exactly, not appended.
      expect(doc['type_ssim']).to eq(['Person'])
      expect(doc['noid_ssi']).to eq(saved.noid)
      expect(doc['display_name_ssi']).to eq('Jane Doe')
      expect(doc['nuid_ssi']).to eq('001234567')
      expect(doc['affiliated_community_ids_ssim']).to eq([community.noid])
      # internal_resource lands automatically, so Cerberus's type-allowlisted
      # catalog naturally excludes Person.
      expect(doc['internal_resource_tesim']).to include('Person')
    end

    it 'makes the Person keyword-searchable by name via the title field' do
      Atlas.persister.save(resource: person)
      # qf targets title_tsim, so a name query matches the Person doc.
      hits = Atlas.index_adapter.connection.get(
        'select', params: { q: 'title_tsim:"Jane Doe"', fl: 'id' }
      ).dig('response', 'docs').pluck('id')
      expect(hits).to include(person.id.to_s)
    end

    it 'is publicly readable so gated discovery does not drop it' do
      # AccessControlsIndexer projects the PersonCreator-set public read group;
      # without it the {!terms f=read_access_group_ssim}public,… filter excludes
      # the Person from every non-admin search.
      doc = person_doc(person, 'read_access_group_ssim')
      expect(doc['read_access_group_ssim']).to eq(['public'])
    end
  end
end
