# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DelegateCreator do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  describe '.call on a Work with no existing :derivative FileSet' do
    it 'creates the derivative FileSet and attaches a Delegate member' do
      delegate = described_class.call(
        resource_id: work.id,
        use:         Role.thumbnail_image.name,
        uri:         'https://iiif.example/thumb.jpg'
      )

      expect(delegate).to be_a(Delegate)
      expect(delegate.use).to eq(Role.thumbnail_image.name)
      expect(delegate.uri).to eq('https://iiif.example/thumb.jpg')

      reloaded = Work.find(work.noid)
      deriv_fs = reloaded.children.find { |c| c.is_a?(FileSet) && c.type == Classification.derivative.name }
      expect(deriv_fs).not_to be_nil
      expect(deriv_fs.member_ids).to include(delegate.id)
    end

    it 'inherits permissions from the parent resource' do
      delegate = described_class.call(
        resource_id: work.id,
        use:         Role.thumbnail_image.name,
        uri:         'https://iiif.example/thumb.jpg'
      )
      expect(delegate.permissions[:edit]).to eq(work.permissions[:edit])
    end

    it 'does not write a preservation envelope for the derivative FileSet or the Delegate' do
      # Force the Work to be created first so its setup-time preservation
      # writes don't count against the expectation below — we only care
      # about envelope activity during the DelegateCreator call.
      work
      expect(PreservationEnvelopeWriter).not_to receive(:call)
      described_class.call(
        resource_id: work.id,
        use:         Role.thumbnail_image.name,
        uri:         'https://iiif.example/thumb.jpg'
      )
    end
  end

  describe '.call on a Work that already has a :derivative FileSet' do
    it 'reuses the existing FileSet rather than creating a second one' do
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

      reloaded = Work.find(work.noid)
      deriv_fs = reloaded.children.select { |c| c.is_a?(FileSet) && c.type == Classification.derivative.name }
      expect(deriv_fs.size).to eq(1)
      expect(deriv_fs.first.member_ids).to include(first.id, second.id)
    end
  end
end
