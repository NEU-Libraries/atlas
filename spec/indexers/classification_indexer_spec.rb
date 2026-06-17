# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ClassificationIndexer do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  # Re-read the projected facet field straight off the Work's Solr doc.
  def classification_in_solr(resource)
    Atlas.index_adapter.connection.get(
      'select', params: { q: %(id:"#{resource.id}"), fl: 'classification_ssim' }
    ).dig('response', 'docs').first&.fetch('classification_ssim', nil)
  end

  describe '#to_solr' do
    it 'returns an empty hash for a Work with no page FileSets (in-progress deposit)' do
      expect(described_class.new(resource: work).to_solr).to eq({})
    end

    it "projects the distinct classifications of the Work's page FileSets" do
      FileSetCreator.call(work_id: work.noid, classification: Classification.image)
      FileSetCreator.call(work_id: work.noid, classification: Classification.text)

      result = described_class.new(resource: Work.find(work.noid)).to_solr
      expect(result[:classification_ssim]).to contain_exactly('Image', 'Text')
    end

    it 'de-duplicates repeated types so a multi-page same-type Work lists it once' do
      FileSetCreator.call(work_id: work.noid, classification: Classification.image, position: 1)
      FileSetCreator.call(work_id: work.noid, classification: Classification.image, position: 2)

      result = described_class.new(resource: Work.find(work.noid)).to_solr
      expect(result[:classification_ssim]).to eq(['Image'])
    end

    it 'ignores metadata/derivative FileSets (page_file_sets already excludes them)' do
      FileSetCreator.call(work_id: work.noid, classification: Classification.image)
      FileSetCreator.call(work_id: work.noid, classification: Classification.derivative)

      result = described_class.new(resource: Work.find(work.noid)).to_solr
      expect(result[:classification_ssim]).to eq(['Image'])
    end

    it 'returns an empty hash for non-Work resources' do
      expect(described_class.new(resource: collection).to_solr).to eq({})
      expect(described_class.new(resource: community).to_solr).to eq({})
      expect(described_class.new(resource: Blob.new).to_solr).to eq({})
      expect(described_class.new(resource: FileSet.new).to_solr).to eq({})
    end
  end

  describe 'end-to-end through the composite indexer' do
    it 'lands classification_ssim on the Work doc when the Work is saved' do
      FileSetCreator.call(work_id: work.noid, classification: Classification.image)
      Atlas.persister.save(resource: Work.find(work.noid))

      expect(classification_in_solr(work)).to contain_exactly('Image')
    end

    it 'refreshes the facet when a page is added to an already-completed Work' do
      Atlas.persister.save(resource: Work.find(work.noid).tap { |w| w.in_progress = false })
      FileSetCreator.call(work_id: work.noid, classification: Classification.image)
      expect(classification_in_solr(work)).to contain_exactly('Image')

      # Adding a second-type page fires FileSetCreator#reproject_classification.
      FileSetCreator.call(work_id: work.noid, classification: Classification.audio)
      expect(classification_in_solr(work)).to contain_exactly('Image', 'Audio')
    end
  end
end
