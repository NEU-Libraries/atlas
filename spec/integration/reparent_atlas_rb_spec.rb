# frozen_string_literal: true

require 'rails_helper'

# Drives the atlas_rb 1.2.1 re-parent surface (Work/Collection/Community
# .reparent) through the real HTTP boundary. Two halves:
#
#  - the happy path, whose headline is the Collection move: it exercises
#    Atlas's synchronous descendant cascade — a moved collection's child must
#    come back carrying the recomputed ancestry end-to-end through the gem.
#  - the rejection path, new in 1.2.1: Atlas's structured 4xx envelopes now
#    surface as typed exceptions rather than a swallowed nil. A structural
#    422 raises AtlasRb::ReparentError (carrying the machine-readable #code),
#    and an authorization 403 — now that re-parent is admin-only — raises
#    AtlasRb::ForbiddenError (carrying #action / #subject).
RSpec.describe 'Re-parenting via atlas_rb', :atlas_rb_server do
  # Admin (wildcard) — re-parent is an admin-only operation, so this is the
  # principal the happy-path moves run as.
  let(:admin_nuid) { '000000004' }

  # A non-admin (edit-rights) principal, for the ForbiddenError path. Created
  # on the shared DB so the Puma server thread resolves it; re-parent is
  # admin-only, so even an edit-rights holder is refused.
  let!(:editor) do
    User.find_by(nuid: '000000002') ||
      User.create!(email: 'editor-reparent@example.invalid', password: SecureRandom.hex(16),
                   nuid: '000000002', name: 'Doe, Jane', role: :privileged)
  end

  describe 'AtlasRb::Work.reparent' do
    it 'moves a Work to a different Collection (no cascade)' do
      community   = CommunityCreator.call
      home        = CollectionCreator.call(parent_id: community.noid)
      destination = CollectionCreator.call(parent_id: community.noid)
      work        = WorkCreator.call(parent_id: home.noid)

      result = AtlasRb::Work.reparent(work.noid, destination.noid, nuid: admin_nuid)

      expect(result['ancestors'].pluck('noid')).to include(destination.noid)
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
      expect(refetched['ancestors'].pluck('noid')).to contain_exactly(home.noid, destination.noid)
    end

    it 'raises AtlasRb::ReparentError (and does not perform) a move into its own descendant' do
      community = CommunityCreator.call
      parent    = CollectionCreator.call(parent_id: community.noid)
      child     = CollectionCreator.call(parent_id: parent.noid)

      # 1.2.1: the structural 422 surfaces as a typed error carrying Atlas's
      # machine-readable discriminator, instead of the swallowed nil of 1.2.0.
      expect do
        AtlasRb::Collection.reparent(parent.noid, child.noid, nuid: admin_nuid)
      end.to raise_error(AtlasRb::ReparentError) { |e|
        expect(e.code).to eq('cycle')
        expect(e.resource_id).to eq(parent.noid)
      }

      # And Atlas refused: the edge is unchanged.
      expect(Collection.find(parent.noid).parent.noid).to eq(community.noid)
    end
  end

  describe 'AtlasRb::Community.reparent' do
    it 'moves a Community under another Community' do
      root        = CommunityCreator.call
      destination = CommunityCreator.call
      community   = CommunityCreator.call(parent_id: root.noid)

      result = AtlasRb::Community.reparent(community.noid, destination.noid, nuid: admin_nuid)

      expect(result['ancestors'].pluck('noid')).to include(destination.noid)
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

  describe '1.2.1 typed rejections' do
    it 'raises AtlasRb::ReparentError with #code for a bad parent type' do
      # A Work may only live under a Collection; a Community parent is a
      # structural 422 (invalid_parent_type), distinct from the cycle case.
      community = CommunityCreator.call
      home      = CollectionCreator.call(parent_id: community.noid)
      work      = WorkCreator.call(parent_id: home.noid)

      expect do
        AtlasRb::Work.reparent(work.noid, community.noid, nuid: admin_nuid)
      end.to raise_error(AtlasRb::ReparentError) { |e|
        expect(e.code).to eq('invalid_parent_type')
        expect(e.resource_id).to eq(work.noid)
      }

      expect(Work.find(work.noid).parent.noid).to eq(home.noid) # unmoved
    end

    it 'raises AtlasRb::ForbiddenError for a non-admin caller (re-parent is admin-only)' do
      community   = CommunityCreator.call
      home        = CollectionCreator.call(parent_id: community.noid)
      destination = CollectionCreator.call(parent_id: community.noid)
      work        = WorkCreator.call(parent_id: home.noid)

      expect do
        AtlasRb::Work.reparent(work.noid, destination.noid, nuid: editor.nuid)
      end.to raise_error(AtlasRb::ForbiddenError) { |e|
        expect(e.action).to eq('reparent')
        expect(e.subject).to eq('Work')
      }

      expect(Work.find(work.noid).parent.noid).to eq(home.noid) # unmoved
    end
  end
end
