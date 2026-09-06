# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Collections via atlas_rb', :atlas_rb_server do
  # Admin (wildcard) — the cheapest principal that satisfies every
  # Ability-gated path under test.
  let(:admin_nuid) { '000000004' }

  let(:community) { CommunityCreator.call }

  it 'round-trips a Collection through the HTTP boundary' do
    created = AtlasRb::Collection.create(community.noid, nuid: admin_nuid)
    expect(created['id']).to be_present

    found = AtlasRb::Collection.find(created['id'], nuid: admin_nuid)
    expect(found['id']).to eq(created['id'])
  end

  it 'updates a Collection via multipart MODS upload' do
    collection = CollectionCreator.call(parent_id: community.noid)

    AtlasRb::Collection.update(collection.noid, Rails.root.join('spec/fixtures/files/work-mods.xml').to_s, nuid: admin_nuid)

    found = AtlasRb::Collection.find(collection.noid, nuid: admin_nuid)
    expect(found['title']).to eq("What's New, Episode 1 - How We Respond to Disaster")
  end

  it 'lists child Work noids of a Collection via HTTP' do
    collection = CollectionCreator.call(parent_id: community.noid)
    AtlasRb::Work.create(collection.noid, nuid: admin_nuid)
    AtlasRb::Work.create(collection.noid, nuid: admin_nuid)

    children = AtlasRb::Collection.children(collection.noid, nuid: admin_nuid)
    expect(children).to be_an(Array)
    expect(children.size).to be >= 2
    expect(children).to all(be_a(String))
  end

  it 'destroys a Collection via HTTP' do
    collection = CollectionCreator.call(parent_id: community.noid)

    AtlasRb::Admin::Collection.destroy(collection.noid, confirm: :i_understand, nuid: admin_nuid)
    expect(Collection.find(collection.noid)).to be_nil
  end

  describe '.set_thumbnails' do
    it 'round-trips the three thumbnail-tier URIs through atlas_rb and surfaces them on the next find' do
      collection = CollectionCreator.call(parent_id: community.noid)

      AtlasRb::Collection.set_thumbnails(
        collection.noid,
        thumbnail:    'https://iiif.example/iiif/3/c.jp2/full/!85,85/0/default.jpg',
        thumbnail_2x: 'https://iiif.example/iiif/3/c.jp2/full/!170,170/0/default.jpg',
        preview:      'https://iiif.example/iiif/3/c.jp2/full/500,/0/default.jpg',
        nuid:         admin_nuid
      )

      found = AtlasRb::Collection.find(collection.noid, nuid: admin_nuid)
      expect(found['thumbnail']).to eq('https://iiif.example/iiif/3/c.jp2/full/!85,85/0/default.jpg')
      expect(found['thumbnail_2x']).to eq('https://iiif.example/iiif/3/c.jp2/full/!170,170/0/default.jpg')
      expect(found['preview']).to eq('https://iiif.example/iiif/3/c.jp2/full/500,/0/default.jpg')
    end
  end
end
