# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SystemContainerIndexer do
  let(:community) { CommunityCreator.call }

  after { Atlas.persister.wipe! }

  def system_container_in_solr(resource)
    Atlas.index_adapter.connection.get(
      'select', params: { q: %(id:"#{resource.id}"), fl: 'system_container_bsi' }
    ).dig('response', 'docs').first&.fetch('system_container_bsi', nil)
  end

  describe '#to_solr' do
    it 'projects system_container_bsi=false for a plain Community' do
      expect(described_class.new(resource: community).to_solr).to eq(system_container_bsi: 'false')
    end

    it 'projects system_container_bsi=true for the auto-provisioned People Community' do
      PersonalRootCreator.call(nuid: '001234567')
      people = Atlas.query.find_all_of_model(model: Community).to_a
                    .find { |c| c.depositor == PersonalRootCreator::PEOPLE_COMMUNITY_DEPOSITOR }
      expect(described_class.new(resource: people).to_solr).to eq(system_container_bsi: 'true')
    end

    it 'returns an empty hash for non-Community resources' do
      collection = CollectionCreator.call(parent_id: community.noid)
      expect(described_class.new(resource: collection).to_solr).to eq({})
      expect(described_class.new(resource: Work.new).to_solr).to eq({})
    end
  end

  describe 'end-to-end through the composite indexer' do
    it 'lands system_container_bsi on the People Community doc when saved' do
      PersonalRootCreator.call(nuid: '001234567')
      people = Atlas.query.find_all_of_model(model: Community).to_a
                    .find { |c| c.depositor == PersonalRootCreator::PEOPLE_COMMUNITY_DEPOSITOR }
      # _bsi is a boolean Solr field, so the written 'true' comes back coerced.
      expect(system_container_in_solr(people)).to be(true)
    end
  end
end
