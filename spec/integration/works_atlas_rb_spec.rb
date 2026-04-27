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
end
