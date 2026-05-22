# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ThumbnailIndexer do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  describe '#to_solr' do
    it 'returns an empty hash when the resource has no derivative FileSet' do
      expect(described_class.new(resource: work).to_solr).to eq({})
    end

    it 'projects only the tiers that exist as Delegates' do
      DelegateCreator.call(
        resource_id: work.id,
        use:         Role.thumbnail_image.name,
        uri:         'https://iiif.example/thumb.jpg'
      )
      DelegateCreator.call(
        resource_id: work.id,
        use:         Role.preview_image.name,
        uri:         'https://iiif.example/preview.jpg'
      )

      result = described_class.new(resource: Work.find(work.noid)).to_solr
      expect(result).to eq(
        thumbnail_ssi: 'https://iiif.example/thumb.jpg',
        preview_ssi:   'https://iiif.example/preview.jpg'
      )
      expect(result).not_to have_key(:thumbnail_2x_ssi)
    end

    it 'projects all three tiers when all three Delegates are present' do
      DelegateCreator.call(resource_id: work.id, use: Role.thumbnail_image.name,    uri: 'https://iiif.example/85.jpg')
      DelegateCreator.call(resource_id: work.id, use: Role.thumbnail_image_2x.name, uri: 'https://iiif.example/170.jpg')
      DelegateCreator.call(resource_id: work.id, use: Role.preview_image.name,      uri: 'https://iiif.example/500.jpg')

      result = described_class.new(resource: Work.find(work.noid)).to_solr
      expect(result).to eq(
        thumbnail_ssi:    'https://iiif.example/85.jpg',
        thumbnail_2x_ssi: 'https://iiif.example/170.jpg',
        preview_ssi:      'https://iiif.example/500.jpg'
      )
    end

    it 'ignores non-thumbnail-family Delegates living in the same derivative FileSet' do
      DelegateCreator.call(resource_id: work.id, use: Role.thumbnail_image.name, uri: 'https://iiif.example/85.jpg')
      DelegateCreator.call(resource_id: work.id, use: Role.small_image.name,     uri: 'https://iiif.example/small.jpg')
      DelegateCreator.call(resource_id: work.id, use: Role.large_image.name,     uri: 'https://iiif.example/large.jpg')

      result = described_class.new(resource: Work.find(work.noid)).to_solr
      expect(result.keys).to eq([:thumbnail_ssi])
      expect(result[:thumbnail_ssi]).to eq('https://iiif.example/85.jpg')
    end

    it 'returns an empty hash for a Blob (no children)' do
      blob = Atlas.persister.save(resource: Blob.new(use: Role.original_file.name))
      expect(described_class.new(resource: blob).to_solr).to eq({})
    end

    it 'returns an empty hash for a Delegate (no children)' do
      delegate = Atlas.persister.save(resource: Delegate.new(use: Role.thumbnail_image.name, uri: 'https://iiif.example/x.jpg'))
      expect(described_class.new(resource: delegate).to_solr).to eq({})
    end
  end
end
