# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Works via atlas_rb', :atlas_rb_server do
  # Admin (wildcard) — the cheapest principal that satisfies every
  # Ability-gated path under test.
  let(:admin_nuid) { '000000004' }

  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }

  it 'round-trips a Work through the HTTP boundary' do
    created = AtlasRb::Work.create(collection.noid, nuid: admin_nuid)
    expect(created['id']).to be_present

    found = AtlasRb::Work.find(created['id'], nuid: admin_nuid)
    expect(found['id']).to eq(created['id'])
  end

  it 'updates a Work via multipart MODS upload' do
    work = WorkCreator.call(parent_id: collection.noid)

    AtlasRb::Work.update(work.noid, Rails.root.join('spec/fixtures/files/work-mods.xml').to_s, nuid: admin_nuid)

    found = AtlasRb::Work.find(work.noid, nuid: admin_nuid)
    expect(found['title']).to eq("What's New - How We Respond to Disaster, Episode 1")
  end

  it 'destroys a Work via HTTP' do
    work = WorkCreator.call(parent_id: collection.noid)

    AtlasRb::Work.destroy(work.noid, nuid: admin_nuid)
    expect(Work.find(work.noid)).to be_nil
  end

  describe '.assets' do
    it 'returns a polymorphic array of Blob and Delegate entries, with thumbnail-family Delegates filtered out' do
      work    = WorkCreator.call(parent_id: collection.noid)
      fixture = Rails.root.join('spec/fixtures/files/example.bin').to_s

      AtlasRb::Blob.create(work.noid, fixture, 'example.bin', nuid: admin_nuid)
      DelegateCreator.call(resource_id: work.id, use: Role.thumbnail_image.name, uri: 'https://iiif.example/thumb.jpg')
      DelegateCreator.call(resource_id: work.id, use: Role.large_image.name,     uri: 'https://iiif.example/large.jpg')

      assets = AtlasRb::Work.assets(work.noid, nuid: admin_nuid)
      uses   = assets.pluck('use').compact

      # The Blob entry has no `use` in the assets shape; the Delegate
      # entries carry their Role names. Thumbnail Image must NOT appear.
      expect(uses).to     include(Role.large_image.name)
      expect(uses).not_to include(Role.thumbnail_image.name)

      blob_entry = assets.find { |a| a['original_filename'] == 'example.bin' }
      expect(blob_entry).not_to be_nil
      expect(blob_entry['size']).to eq(File.size(fixture))
    end
  end

  describe '.find — thumbnail-family projections' do
    it 'surfaces thumbnail, thumbnail_2x, and preview on the Work JSON when the Delegates exist' do
      work = WorkCreator.call(parent_id: collection.noid)
      DelegateCreator.call(resource_id: work.id, use: Role.thumbnail_image.name,    uri: 'https://iiif.example/85.jpg')
      DelegateCreator.call(resource_id: work.id, use: Role.thumbnail_image_2x.name, uri: 'https://iiif.example/170.jpg')
      DelegateCreator.call(resource_id: work.id, use: Role.preview_image.name,      uri: 'https://iiif.example/500.jpg')

      found = AtlasRb::Work.find(work.noid, nuid: admin_nuid)
      expect(found['thumbnail']).to    eq('https://iiif.example/85.jpg')
      expect(found['thumbnail_2x']).to eq('https://iiif.example/170.jpg')
      expect(found['preview']).to      eq('https://iiif.example/500.jpg')
    end

    it 'returns null for tiers whose Delegate has not been minted' do
      work = WorkCreator.call(parent_id: collection.noid)
      DelegateCreator.call(resource_id: work.id, use: Role.thumbnail_image.name, uri: 'https://iiif.example/85.jpg')

      found = AtlasRb::Work.find(work.noid, nuid: admin_nuid)
      expect(found['thumbnail']).to    eq('https://iiif.example/85.jpg')
      expect(found['thumbnail_2x']).to be_nil
      expect(found['preview']).to      be_nil
    end
  end

  describe '.set_thumbnails' do
    it 'round-trips the three thumbnail-tier URIs through atlas_rb and surfaces them on the next find' do
      work = WorkCreator.call(parent_id: collection.noid)

      AtlasRb::Work.set_thumbnails(
        work.noid,
        thumbnail:    'https://iiif.example/iiif/3/abc.jp2/full/!85,85/0/default.jpg',
        thumbnail_2x: 'https://iiif.example/iiif/3/abc.jp2/full/!170,170/0/default.jpg',
        preview:      'https://iiif.example/iiif/3/abc.jp2/full/500,/0/default.jpg',
        nuid:         admin_nuid
      )

      found = AtlasRb::Work.find(work.noid, nuid: admin_nuid)
      expect(found['thumbnail']).to eq('https://iiif.example/iiif/3/abc.jp2/full/!85,85/0/default.jpg')
      expect(found['thumbnail_2x']).to eq('https://iiif.example/iiif/3/abc.jp2/full/!170,170/0/default.jpg')
      expect(found['preview']).to eq('https://iiif.example/iiif/3/abc.jp2/full/500,/0/default.jpg')
    end

    it 'upserts in place — repeated calls hold one Delegate per role with the latest URI' do
      work = WorkCreator.call(parent_id: collection.noid)
      uri_v1 = 'https://iiif.example/iiif/3/abc.jp2/full/!85,85/0/default.jpg'
      uri_v2 = 'https://iiif.example/iiif/3/abc.jp2/full/!85,85/0/default.jpg?v2'

      AtlasRb::Work.set_thumbnails(work.noid, thumbnail: uri_v1, nuid: admin_nuid)
      AtlasRb::Work.set_thumbnails(work.noid, thumbnail: uri_v2, nuid: admin_nuid)

      reloaded = Work.find(work.noid)
      deriv_fs = reloaded.children.find { |c| c.is_a?(FileSet) && c.type == Classification.derivative.name }
      members = Atlas.query.find_members(resource: deriv_fs).to_a
                     .select { |m| m.is_a?(Delegate) && m.use == Role.thumbnail_image.name }
      expect(members.size).to eq(1)
      expect(members.first.uri).to eq(uri_v2)
    end

    it 'leaves tiers untouched when their key is omitted' do
      work = WorkCreator.call(parent_id: collection.noid)
      preview_uri = 'https://iiif.example/iiif/3/abc.jp2/full/500,/0/default.jpg'

      AtlasRb::Work.set_thumbnails(work.noid, preview: preview_uri, nuid: admin_nuid)
      AtlasRb::Work.set_thumbnails(work.noid, thumbnail: 'https://iiif.example/iiif/3/abc.jp2/full/!85,85/0/default.jpg', nuid: admin_nuid)

      found = AtlasRb::Work.find(work.noid, nuid: admin_nuid)
      expect(found['preview']).to eq(preview_uri)
      expect(found['thumbnail']).to eq('https://iiif.example/iiif/3/abc.jp2/full/!85,85/0/default.jpg')
    end
  end

  describe '.set_image_derivatives' do
    it 'attaches small/medium/large Delegates that surface in .assets' do
      work = WorkCreator.call(parent_id: collection.noid)

      AtlasRb::Work.set_image_derivatives(
        work.noid,
        small:  'https://iiif.example/iiif/3/abc.jp2/full/800,/0/default.jpg',
        medium: 'https://iiif.example/iiif/3/abc.jp2/full/1600,/0/default.jpg',
        large:  'https://iiif.example/iiif/3/abc.jp2/full/full/0/default.jpg',
        nuid:   admin_nuid
      )

      assets = AtlasRb::Work.assets(work.noid, nuid: admin_nuid)
      by_use = assets.to_h { |a| [a['use'], a['uri']] }
      expect(by_use[Role.small_image.name]).to eq('https://iiif.example/iiif/3/abc.jp2/full/800,/0/default.jpg')
      expect(by_use[Role.medium_image.name]).to eq('https://iiif.example/iiif/3/abc.jp2/full/1600,/0/default.jpg')
      expect(by_use[Role.large_image.name]).to eq('https://iiif.example/iiif/3/abc.jp2/full/full/0/default.jpg')
    end

    it 'leaves tiers untouched when their key is omitted' do
      work = WorkCreator.call(parent_id: collection.noid)
      large = 'https://iiif.example/iiif/3/abc.jp2/full/full/0/default.jpg'

      AtlasRb::Work.set_image_derivatives(work.noid, large: large, nuid: admin_nuid)
      AtlasRb::Work.set_image_derivatives(work.noid, small: 'https://iiif.example/iiif/3/abc.jp2/full/800,/0/default.jpg', nuid: admin_nuid)

      assets = AtlasRb::Work.assets(work.noid, nuid: admin_nuid)
      uses = assets.pluck('use').compact
      expect(uses).to contain_exactly(Role.small_image.name, Role.large_image.name)
    end
  end
end
