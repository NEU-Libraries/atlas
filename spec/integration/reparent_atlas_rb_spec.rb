# frozen_string_literal: true

require 'rails_helper'

# Drives the atlas_rb 1.2.0 re-parent surface (Work/Collection/Community
# .reparent) through the real HTTP boundary. The headline assertion is the
# Collection move: it exercises Atlas's synchronous descendant cascade —
# a moved collection's child must come back carrying the recomputed ancestry
# end-to-end through the gem.
RSpec.describe 'Re-parenting via atlas_rb', :atlas_rb_server do
  # Admin (wildcard) — the cheapest principal that satisfies the two-sided
  # edit-rights gate on both the moved node and the destination.
  let(:admin_nuid) { '000000004' }

  describe 'AtlasRb::Work.reparent' do
    it 'moves a Work to a different Collection (no cascade)' do
      community   = CommunityCreator.call
      home        = CollectionCreator.call(parent_id: community.noid)
      destination = CollectionCreator.call(parent_id: community.noid)
      work        = WorkCreator.call(parent_id: home.noid)

      result = AtlasRb::Work.reparent(work.noid, destination.noid, nuid: admin_nuid)

      expect(result['ancestors'].map(&:first)).to include(destination.noid)
      expect(Work.find(work.noid).parent.noid).to eq(destination.noid)
    end
  end

  describe 'AtlasRb::Collection.reparent' do
    it 'moves a Collection and recomputes its descendant collections\' ancestry (cascade)' do
      community   = CommunityCreator.call
      destination = CommunityCreator.call
      home        = CollectionCreator.call(parent_id: community.noid)
      child       = CollectionCreator.call(parent_id: home.noid)

      AtlasRb::Collection.reparent(home.noid, destination.noid, nuid: admin_nuid)

      expect(Collection.find(home.noid).parent.noid).to eq(destination.noid)

      # The cascade: child rode along — fetched fresh through the gem, its
      # ancestor chain now runs through the new destination.
      refetched = AtlasRb::Collection.find(child.noid, nuid: admin_nuid)
      expect(refetched['ancestors'].map(&:first)).to contain_exactly(home.noid, destination.noid)
    end

    it 'rejects (and does not perform) a move into the collection\'s own descendant' do
      community = CommunityCreator.call
      parent    = CollectionCreator.call(parent_id: community.noid)
      child     = CollectionCreator.call(parent_id: parent.noid)

      AtlasRb::Collection.reparent(parent.noid, child.noid, nuid: admin_nuid)

      # The important assertion is Atlas's refusal: the edge is unchanged.
      expect(Collection.find(parent.noid).parent.noid).to eq(community.noid)
    end
  end

  describe 'AtlasRb::Community.reparent' do
    it 'moves a Community under another Community' do
      root        = CommunityCreator.call
      destination = CommunityCreator.call
      community   = CommunityCreator.call(parent_id: root.noid)

      result = AtlasRb::Community.reparent(community.noid, destination.noid, nuid: admin_nuid)

      expect(result['ancestors'].map(&:first)).to include(destination.noid)
      expect(Community.find(community.noid).parent.noid).to eq(destination.noid)
    end

    it 'moves a Community to the top of the tree with a nil parent' do
      root      = CommunityCreator.call
      community = CommunityCreator.call(parent_id: root.noid)

      result = AtlasRb::Community.reparent(community.noid, nil, nuid: admin_nuid)

      expect(result['ancestors']).to eq([])
      expect(Community.find(community.noid).a_member_of).to be_nil
    end
  end
end
