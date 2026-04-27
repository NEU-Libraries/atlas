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
end
