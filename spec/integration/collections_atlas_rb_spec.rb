# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Collections via atlas_rb', :atlas_rb_server do
  let(:community) { CommunityCreator.call }

  it 'round-trips a Collection through the HTTP boundary' do
    created = AtlasRb::Collection.create(community.noid)
    expect(created['id']).to be_present

    found = AtlasRb::Collection.find(created['id'])
    expect(found['id']).to eq(created['id'])
  end

  it 'updates a Collection via multipart MODS upload' do
    collection = CollectionCreator.call(parent_id: community.noid)

    AtlasRb::Collection.update(collection.noid, Rails.root.join('spec/fixtures/files/work-mods.xml').to_s)

    found = AtlasRb::Collection.find(collection.noid)
    expect(found['title']).to eq("What's New - How We Respond to Disaster, Episode 1")
  end

  it 'lists child Work noids of a Collection via HTTP' do
    collection = CollectionCreator.call(parent_id: community.noid)
    AtlasRb::Work.create(collection.noid)
    AtlasRb::Work.create(collection.noid)

    children = AtlasRb::Collection.children(collection.noid)
    expect(children).to be_an(Array)
    expect(children.size).to be >= 2
    expect(children).to all(be_a(String))
  end

  it 'destroys a Collection via HTTP' do
    collection = CollectionCreator.call(parent_id: community.noid)

    AtlasRb::Collection.destroy(collection.noid)
    expect(Collection.find(collection.noid)).to be_nil
  end
end
