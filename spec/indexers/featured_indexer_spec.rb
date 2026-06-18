# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FeaturedIndexer do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }

  after { Atlas.persister.wipe! }

  def featured_in_solr(resource)
    Atlas.index_adapter.connection.get(
      'select', params: { q: %(id:"#{resource.id}"), fl: 'featured_bsi' }
    ).dig('response', 'docs').first&.fetch('featured_bsi', nil)
  end

  describe '#to_solr' do
    it 'projects featured_bsi=false for a plain Collection' do
      expect(described_class.new(resource: collection).to_solr).to eq(featured_bsi: 'false')
    end

    it 'projects featured_bsi=true for a showcase Collection' do
      showcase = CollectionCreator.call(parent_id: community.noid, featured: true)
      expect(described_class.new(resource: showcase).to_solr).to eq(featured_bsi: 'true')
    end

    it 'returns an empty hash for non-Collection resources' do
      expect(described_class.new(resource: community).to_solr).to eq({})
      expect(described_class.new(resource: Work.new).to_solr).to eq({})
    end
  end

  describe 'end-to-end through the composite indexer' do
    it 'lands featured_bsi on the Collection doc when saved' do
      showcase = CollectionCreator.call(parent_id: community.noid, featured: true)
      # _bsi is a boolean Solr field, so the written 'true' comes back coerced.
      expect(featured_in_solr(showcase)).to be(true)
    end
  end
end
