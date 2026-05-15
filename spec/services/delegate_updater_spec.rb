# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DelegateUpdater do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  describe '.call when no Delegate exists for the (resource, use) pair' do
    it 'falls through to DelegateCreator and creates a new Delegate' do
      result = described_class.call(
        resource_id: work.id,
        use:         Role.thumbnail_image.name,
        uri:         'https://iiif.example/thumb.jpg'
      )
      expect(result).to be_a(Delegate)
      expect(result.uri).to eq('https://iiif.example/thumb.jpg')
    end
  end

  describe '.call when a Delegate already exists for the (resource, use) pair' do
    it 'updates the existing Delegate uri without creating a new one' do
      original = described_class.call(
        resource_id: work.id,
        use:         Role.thumbnail_image.name,
        uri:         'https://iiif.example/thumb-v1.jpg'
      )
      updated = described_class.call(
        resource_id: work.id,
        use:         Role.thumbnail_image.name,
        uri:         'https://iiif.example/thumb-v2.jpg'
      )

      expect(updated.id).to eq(original.id)
      expect(updated.uri).to eq('https://iiif.example/thumb-v2.jpg')

      reloaded = Work.find(work.noid)
      deriv_fs = reloaded.children.find { |c| c.is_a?(FileSet) && c.type == Classification.derivative.name }
      members  = Atlas.query.find_members(resource: deriv_fs).to_a
      expect(members.size).to eq(1)
    end
  end

  describe '.call with a different `use` on a resource that already has another Delegate' do
    it 'creates a second Delegate in the same derivative FileSet' do
      first = described_class.call(
        resource_id: work.id,
        use:         Role.thumbnail_image.name,
        uri:         'https://iiif.example/thumb.jpg'
      )
      second = described_class.call(
        resource_id: work.id,
        use:         Role.service_file.name,
        uri:         'https://iiif.example/service.jpg'
      )

      expect(second.id).not_to eq(first.id)
      reloaded = Work.find(work.noid)
      deriv_fs = reloaded.children.find { |c| c.is_a?(FileSet) && c.type == Classification.derivative.name }
      expect(deriv_fs.member_ids).to include(first.id, second.id)
    end
  end
end
