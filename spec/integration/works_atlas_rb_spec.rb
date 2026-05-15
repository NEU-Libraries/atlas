# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Works via atlas_rb', :atlas_rb_server do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }

  it 'round-trips a Work through the HTTP boundary' do
    created = AtlasRb::Work.create(collection.noid)
    expect(created['id']).to be_present

    found = AtlasRb::Work.find(created['id'])
    expect(found['id']).to eq(created['id'])
  end

  it 'updates a Work via multipart MODS upload' do
    work = WorkCreator.call(parent_id: collection.noid)

    AtlasRb::Work.update(work.noid, Rails.root.join('spec/fixtures/files/work-mods.xml').to_s)

    found = AtlasRb::Work.find(work.noid)
    expect(found['title']).to eq("What's New - How We Respond to Disaster, Episode 1")
  end

  it 'destroys a Work via HTTP' do
    work = WorkCreator.call(parent_id: collection.noid)

    AtlasRb::Work.destroy(work.noid)
    expect(Work.find(work.noid)).to be_nil
  end

  describe '.assets' do
    it 'returns a polymorphic array of Blob and Delegate entries, with thumbnail-family Delegates filtered out' do
      work    = WorkCreator.call(parent_id: collection.noid)
      fixture = Rails.root.join('spec/fixtures/files/example.bin').to_s

      AtlasRb::Blob.create(work.noid, fixture, 'example.bin')
      DelegateCreator.call(resource_id: work.id, use: Role.thumbnail_image.name, uri: 'https://iiif.example/thumb.jpg')
      DelegateCreator.call(resource_id: work.id, use: Role.large_image.name,     uri: 'https://iiif.example/large.jpg')

      assets = AtlasRb::Work.assets(work.noid)
      uses   = assets.map { |a| a['use'] }.compact

      # The Blob entry has no `use` in the assets shape; the Delegate
      # entries carry their Role names. Thumbnail Image must NOT appear.
      expect(uses).to     include(Role.large_image.name)
      expect(uses).not_to include(Role.thumbnail_image.name)

      blob_entry = assets.find { |a| a['original_filename'] == 'example.bin' }
      expect(blob_entry).not_to be_nil
      expect(blob_entry['size']).to eq(File.size(fixture))
    end
  end

  describe '.files (deprecated alias)' do
    it 'returns the same payload as .assets via the /files bridge route' do
      work = WorkCreator.call(parent_id: collection.noid)
      DelegateCreator.call(resource_id: work.id, use: Role.large_image.name, uri: 'https://iiif.example/large.jpg')

      assets = AtlasRb::Work.assets(work.noid)
      files  = AtlasRb::Work.files(work.noid)

      # Both call the same underlying action — Atlas keeps /works/:id/files
      # as a bridge while Cerberus migrates. The two responses should match
      # element-for-element.
      expect(files.map { |a| a['use'] || a['original_filename'] })
        .to eq(assets.map { |a| a['use'] || a['original_filename'] })
    end
  end

  describe '.find — thumbnail-family projections' do
    it 'surfaces thumbnail, thumbnail_2x, and preview on the Work JSON when the Delegates exist' do
      work = WorkCreator.call(parent_id: collection.noid)
      DelegateCreator.call(resource_id: work.id, use: Role.thumbnail_image.name,    uri: 'https://iiif.example/85.jpg')
      DelegateCreator.call(resource_id: work.id, use: Role.thumbnail_image_2x.name, uri: 'https://iiif.example/170.jpg')
      DelegateCreator.call(resource_id: work.id, use: Role.preview_image.name,      uri: 'https://iiif.example/500.jpg')

      found = AtlasRb::Work.find(work.noid)
      expect(found['thumbnail']).to    eq('https://iiif.example/85.jpg')
      expect(found['thumbnail_2x']).to eq('https://iiif.example/170.jpg')
      expect(found['preview']).to      eq('https://iiif.example/500.jpg')
    end

    it 'returns null for tiers whose Delegate has not been minted' do
      work = WorkCreator.call(parent_id: collection.noid)
      DelegateCreator.call(resource_id: work.id, use: Role.thumbnail_image.name, uri: 'https://iiif.example/85.jpg')

      found = AtlasRb::Work.find(work.noid)
      expect(found['thumbnail']).to    eq('https://iiif.example/85.jpg')
      expect(found['thumbnail_2x']).to be_nil
      expect(found['preview']).to      be_nil
    end
  end

  describe 'PATCH metadata[thumbnail]' do
    it 'round-trips a thumbnail URI through atlas_rb and surfaces it on the next find' do
      work = WorkCreator.call(parent_id: collection.noid)
      uri  = 'https://iiif.example/iiif/3/abc.jp2/full/!85,85/0/default.jpg'

      AtlasRb::Work.metadata(work.noid, thumbnail: uri)
      expect(AtlasRb::Work.find(work.noid)['thumbnail']).to eq(uri)

      # Repeated PATCH upserts in place: the derivative FileSet still holds
      # exactly one thumbnail_image Delegate, just with the newer URI.
      uri_v2 = 'https://iiif.example/iiif/3/abc.jp2/full/!85,85/0/default.jpg?v2'
      AtlasRb::Work.metadata(work.noid, thumbnail: uri_v2)

      reloaded = Work.find(work.noid)
      deriv_fs = reloaded.children.find { |c| c.is_a?(FileSet) && c.type == Classification.derivative.name }
      members  = Atlas.query.find_members(resource: deriv_fs).to_a.select { |m| m.is_a?(Delegate) && m.use == Role.thumbnail_image.name }
      expect(members.size).to    eq(1)
      expect(members.first.uri).to eq(uri_v2)
    end
  end
end
