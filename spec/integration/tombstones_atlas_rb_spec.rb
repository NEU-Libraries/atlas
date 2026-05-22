# frozen_string_literal: true

require 'rails_helper'

# Round-trips the tombstone/restore bindings introduced in atlas_rb 0.0.91
# across all three resource classes. Each example drives the call through
# the HTTP boundary and re-fetches via atlas_rb to confirm the persisted
# state surfaced by the show endpoint matches expectations.
RSpec.describe 'Tombstone bindings via atlas_rb', :atlas_rb_server do
  # Admin (wildcard) — required so the tombstone/restore call gets past
  # Atlas's Ability layer. The audit-stamp behavior under test is
  # independent of who the actor is.
  let(:nuid) { '000000004' }

  describe 'AtlasRb::Work' do
    let(:community)  { CommunityCreator.call }
    let(:collection) { CollectionCreator.call(parent_id: community.noid) }

    it 'tombstones a Work and stamps the audit fields' do
      work = WorkCreator.call(parent_id: collection.noid)

      AtlasRb::Work.tombstone(work.noid, nuid: nuid)

      found = AtlasRb::Work.find(work.noid, nuid: nuid)
      expect(found['tombstoned']).to be true
      expect(found['tombstoned_at']).to be_present
      expect(found['tombstoned_by']).to eq(nuid)
    end

    it 'restores a tombstoned Work and clears the audit fields' do
      work = WorkCreator.call(parent_id: collection.noid)
      AtlasRb::Work.tombstone(work.noid, nuid: nuid)

      AtlasRb::Work.restore(work.noid, nuid: nuid)

      found = AtlasRb::Work.find(work.noid, nuid: nuid)
      expect(found['tombstoned']).to be false
      expect(found['tombstoned_at']).to be_blank
      expect(found['tombstoned_by']).to be_blank
    end
  end

  describe 'AtlasRb::Collection' do
    let(:community) { CommunityCreator.call }

    it 'tombstones an empty Collection and stamps the audit fields' do
      collection = CollectionCreator.call(parent_id: community.noid)

      AtlasRb::Collection.tombstone(collection.noid, nuid: nuid)

      found = AtlasRb::Collection.find(collection.noid, nuid: nuid)
      expect(found['tombstoned']).to be true
      expect(found['tombstoned_at']).to be_present
      expect(found['tombstoned_by']).to eq(nuid)
    end

    it 'restores a tombstoned Collection and clears the audit fields' do
      collection = CollectionCreator.call(parent_id: community.noid)
      AtlasRb::Collection.tombstone(collection.noid, nuid: nuid)

      AtlasRb::Collection.restore(collection.noid, nuid: nuid)

      found = AtlasRb::Collection.find(collection.noid, nuid: nuid)
      expect(found['tombstoned']).to be false
      expect(found['tombstoned_at']).to be_blank
      expect(found['tombstoned_by']).to be_blank
    end
  end

  describe 'AtlasRb::Community' do
    it 'tombstones an empty Community and stamps the audit fields' do
      community = CommunityCreator.call

      AtlasRb::Community.tombstone(community.noid, nuid: nuid)

      found = AtlasRb::Community.find(community.noid, nuid: nuid)
      expect(found['tombstoned']).to be true
      expect(found['tombstoned_at']).to be_present
      expect(found['tombstoned_by']).to eq(nuid)
    end

    it 'restores a tombstoned Community and clears the audit fields' do
      community = CommunityCreator.call
      AtlasRb::Community.tombstone(community.noid, nuid: nuid)

      AtlasRb::Community.restore(community.noid, nuid: nuid)

      found = AtlasRb::Community.find(community.noid, nuid: nuid)
      expect(found['tombstoned']).to be false
      expect(found['tombstoned_at']).to be_blank
      expect(found['tombstoned_by']).to be_blank
    end
  end
end
