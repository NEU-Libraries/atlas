# frozen_string_literal: true

require 'rails_helper'

# atlas_rb 1.3.1 — AtlasRb::Resource.mods_versions / mods_version wrap
# GET /resources/:id/mods/versions[/:version_id] (Atlas's ResourcesController).
# Cerberus consumes these for the MODS history / diff surface. Exercised here
# end-to-end through the live server: the binding's URL shape, header
# threading, and the two distinct return shapes (Mash envelope vs raw XML
# body) are all proven against the real endpoints.
RSpec.describe 'MODS version history via atlas_rb', :atlas_rb_server do
  # Admin (wildcard): the versions list is admin-gated (it carries
  # audit-derived attribution), and the HTTP MODS edit needs an authenticated
  # actor to emit the correlated `mods` AuditEvent.
  let(:admin_nuid) { '000000004' }

  let(:community)    { CommunityCreator.call }
  let(:collection)   { CollectionCreator.call(parent_id: community.noid) }
  let(:mods_fixture) { Rails.root.join('spec/fixtures/files/work-mods.xml').to_s }

  it 'lists versions (newest first, editor correlated) and fetches a version’s raw XML' do
    work = WorkCreator.call(parent_id: collection.noid)
    # Edit MODS over the wire so Atlas mints a new version AND emits the
    # correlated `mods` AuditEvent attributed to the acting NUID.
    AtlasRb::Work.update(work.noid, mods_fixture, nuid: admin_nuid)

    envelope = AtlasRb::Resource.mods_versions(work.noid, nuid: admin_nuid)
    expect(envelope['resource_id']).to eq(work.noid)
    expect(envelope['versions']).to be_an(Array)
    expect(envelope['versions'].length).to be >= 2 # seed + edit

    # Labels are opaque OCFL vN — assert shape and ordering, not literal values.
    newest = envelope['versions'].first
    expect(newest['version_id']).to match(/\Av\d+\z/)
    expect(newest['actor_nuid']).to eq(admin_nuid)
    expect(newest['source']).to eq('mods')

    # mods_version returns the raw XML body (like Work.mods), not a Mash.
    xml = AtlasRb::Resource.mods_version(work.noid, newest['version_id'], nuid: admin_nuid)
    expect(xml).to be_a(String)
    expect(xml).to include("What's New") # title from the edited fixture
  end

  it 'returns a well-formed empty envelope for a resource with no MODS' do
    envelope = AtlasRb::Resource.mods_versions('no-such-resource', nuid: admin_nuid)

    expect(envelope['resource_id']).to eq('no-such-resource')
    expect(envelope['versions']).to eq([])
  end
end
