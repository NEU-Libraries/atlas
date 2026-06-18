# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GenreIndexer do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  # Re-read the projected facet field straight off the Work's Solr doc.
  def genre_in_solr(resource)
    Atlas.index_adapter.connection.get(
      'select', params: { q: %(id:"#{resource.id}"), fl: 'genre_ssim' }
    ).dig('response', 'docs').first&.fetch('genre_ssim', nil)
  end

  describe '#to_solr' do
    it 'returns an empty hash for a Work with no genre' do
      expect(described_class.new(resource: work).to_solr).to eq({})
    end

    it "projects the Work's MODS genre(s) onto genre_ssim" do
      set_mods_genres!(work, ['Research Publications', 'Datasets'])

      result = described_class.new(resource: Work.find(work.noid)).to_solr
      expect(result[:genre_ssim]).to contain_exactly('Research Publications', 'Datasets')
    end

    it 'de-duplicates repeated genres' do
      set_mods_genres!(work, ['Theses and Dissertations', 'Theses and Dissertations'])

      result = described_class.new(resource: Work.find(work.noid)).to_solr
      expect(result[:genre_ssim]).to eq(['Theses and Dissertations'])
    end

    it 'returns an empty hash for non-Work resources' do
      expect(described_class.new(resource: collection).to_solr).to eq({})
      expect(described_class.new(resource: community).to_solr).to eq({})
      expect(described_class.new(resource: Blob.new).to_solr).to eq({})
      expect(described_class.new(resource: FileSet.new).to_solr).to eq({})
    end
  end

  describe 'end-to-end through the composite indexer' do
    it 'lands genre_ssim on the Work doc when the Work is saved' do
      set_mods_genres!(work, ['Presentations'])
      Atlas.persister.save(resource: Work.find(work.noid))

      expect(genre_in_solr(work)).to contain_exactly('Presentations')
    end

    it 'has no genre_ssim on the doc for a Work with no genre' do
      Atlas.persister.save(resource: Work.find(work.noid))

      expect(genre_in_solr(work)).to be_nil
    end
  end
end
