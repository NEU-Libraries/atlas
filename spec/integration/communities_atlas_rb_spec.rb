# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Communities via atlas_rb', :atlas_rb_server do
  it 'round-trips a Community through the HTTP boundary' do
    parent = CommunityCreator.call

    created = AtlasRb::Community.create(parent.noid)
    expect(created['id']).to be_present

    found = AtlasRb::Community.find(created['id'])
    expect(found['id']).to eq(created['id'])
  end

  it 'lists children of a Community via HTTP' do
    parent = CommunityCreator.call
    AtlasRb::Community.create(parent.noid)
    AtlasRb::Community.create(parent.noid)

    children = AtlasRb::Community.children(parent.noid)
    expect(children).to be_an(Array)
    expect(children.size).to be >= 2
  end

  it 'destroys a Community via HTTP' do
    parent = CommunityCreator.call
    created = AtlasRb::Community.create(parent.noid)

    AtlasRb::Community.destroy(created['id'])
    expect(Community.find(created['id'])).to be_nil
  end

  describe '.set_thumbnails' do
    it 'round-trips the three thumbnail-tier URIs through atlas_rb and surfaces them on the next find' do
      community = CommunityCreator.call

      AtlasRb::Community.set_thumbnails(
        community.noid,
        thumbnail: 'https://iiif.example/iiif/3/m.jp2/full/!85,85/0/default.jpg',
        thumbnail_2x: 'https://iiif.example/iiif/3/m.jp2/full/!170,170/0/default.jpg',
        preview: 'https://iiif.example/iiif/3/m.jp2/full/500,/0/default.jpg'
      )

      found = AtlasRb::Community.find(community.noid)
      expect(found['thumbnail']).to eq('https://iiif.example/iiif/3/m.jp2/full/!85,85/0/default.jpg')
      expect(found['thumbnail_2x']).to eq('https://iiif.example/iiif/3/m.jp2/full/!170,170/0/default.jpg')
      expect(found['preview']).to eq('https://iiif.example/iiif/3/m.jp2/full/500,/0/default.jpg')
    end
  end
end
