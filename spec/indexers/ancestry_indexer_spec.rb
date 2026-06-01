# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AncestryIndexer do
  describe '#to_solr' do
    let(:community)  { Atlas.persister.save(resource: Community.new) }
    let(:collection) { Atlas.persister.save(resource: Collection.new(a_member_of: community.id)) }
    let(:nested)     { Atlas.persister.save(resource: Collection.new(a_member_of: collection.id)) }

    it 'emits the full ancestor chain (noids) for a nested collection' do
      result = described_class.new(resource: nested).to_solr

      expect(result['ancestor_ids_ssim']).to contain_exactly(collection.noid, community.noid)
    end

    it 'emits an empty chain for a top-level community' do
      expect(described_class.new(resource: community).to_solr).to eq('ancestor_ids_ssim' => [])
    end

    it 'emits raw noids, not id-prefixed Valkyrie UUIDs' do
      result = described_class.new(resource: nested).to_solr

      result['ancestor_ids_ssim'].each do |value|
        expect(value).not_to start_with('id-')
        expect(value).not_to include('-') # noids have no hyphens; UUIDs do
      end
    end

    it 'excludes Works (the field never lands on the 544k bulk of the graph)' do
      work = Atlas.persister.save(resource: Work.new(a_member_of: collection.id))

      expect(described_class.new(resource: work).to_solr).to eq({})
    end

    it 'excludes FileSets and Blobs (only the collection/community backbone is indexed)' do
      expect(described_class.new(resource: FileSet.new).to_solr).to eq({})
      expect(described_class.new(resource: Blob.new).to_solr).to eq({})
    end
  end
end
