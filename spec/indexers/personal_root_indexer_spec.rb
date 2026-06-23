# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PersonalRootIndexer do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }

  after { Atlas.persister.wipe! }

  def personal_root_in_solr(resource)
    Atlas.index_adapter.connection.get(
      'select', params: { q: %(id:"#{resource.id}"), fl: 'personal_root_bsi' }
    ).dig('response', 'docs').first&.fetch('personal_root_bsi', nil)
  end

  describe '#to_solr' do
    it 'projects personal_root_bsi=false for a plain Collection' do
      expect(described_class.new(resource: collection).to_solr).to eq(personal_root_bsi: 'false')
    end

    it 'projects personal_root_bsi=true for a personal-root Collection' do
      root = PersonalRootCreator.call(nuid: '001234567')
      expect(described_class.new(resource: root).to_solr).to eq(personal_root_bsi: 'true')
    end

    it 'returns an empty hash for non-Collection resources' do
      expect(described_class.new(resource: community).to_solr).to eq({})
      expect(described_class.new(resource: Work.new).to_solr).to eq({})
    end
  end

  describe 'end-to-end through the composite indexer' do
    it 'lands personal_root_bsi on the personal-root doc when saved' do
      root = PersonalRootCreator.call(nuid: '001234567')
      # _bsi is a boolean Solr field, so the written 'true' comes back coerced.
      expect(personal_root_in_solr(root)).to be(true)
    end
  end
end
