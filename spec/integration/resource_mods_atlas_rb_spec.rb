# frozen_string_literal: true

require 'rails_helper'

# AtlasRb::Resource.mods wraps GET /resources/:id/mods — type-agnostic current
# MODS. A caller holding only a NOID (no klass) fetches descriptive MODS in one
# call, instead of resolving the type first and dispatching to the typed route.
# Output is byte-identical to the typed /works|collections|communities/:id/mods
# routes. Proven end-to-end through the live server: URL shape, format suffix
# (JSON default / .xml), polymorphic dispatch, and byte-parity with the typed
# wrappers.
RSpec.describe 'Type-agnostic current MODS via atlas_rb', :atlas_rb_server do
  let(:admin_nuid)   { '000000004' }
  let(:community)    { CommunityCreator.call }
  let(:collection)   { CollectionCreator.call(parent_id: community.noid) }
  let(:mods_fixture) { Rails.root.join('spec/fixtures/files/work-mods.xml').to_s }

  it 'fetches a Work’s current MODS as XML and as the default JSON' do
    work = WorkCreator.call(parent_id: collection.noid)
    AtlasRb::Work.update(work.noid, mods_fixture, nuid: admin_nuid)

    xml = AtlasRb::Resource.mods(work.noid, 'xml', nuid: admin_nuid)
    expect(xml).to be_a(String)
    expect(xml).to start_with('<?xml')
    expect(xml).to include("What's New") # title from the edited fixture

    json = AtlasRb::Resource.mods(work.noid, nuid: admin_nuid) # kind omitted → JSON default
    expect(JSON.parse(json)).to have_key('work')
  end

  it 'resolves polymorphically for Collection and Community' do
    expect(AtlasRb::Resource.mods(collection.noid, 'xml', nuid: admin_nuid)).to start_with('<?xml')
    expect(AtlasRb::Resource.mods(community.noid, 'xml', nuid: admin_nuid)).to start_with('<?xml')

    expect(JSON.parse(AtlasRb::Resource.mods(collection.noid, nuid: admin_nuid))).to have_key('collection')
    expect(JSON.parse(AtlasRb::Resource.mods(community.noid, nuid: admin_nuid))).to have_key('community')
  end

  it 'is byte-identical to the typed .mods wrappers (no drift)' do
    work = WorkCreator.call(parent_id: collection.noid)

    expect(AtlasRb::Resource.mods(work.noid, 'xml', nuid: admin_nuid))
      .to eq(AtlasRb::Work.mods(work.noid, 'xml', nuid: admin_nuid))
    expect(AtlasRb::Resource.mods(collection.noid, nuid: admin_nuid))
      .to eq(AtlasRb::Collection.mods(collection.noid, nuid: admin_nuid))
  end

  it 'returns an empty body for an unknown id (404)' do
    expect(AtlasRb::Resource.mods('no-such-resource', 'xml', nuid: admin_nuid)).to be_blank
  end
end
