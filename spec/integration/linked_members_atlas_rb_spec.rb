# frozen_string_literal: true

require 'rails_helper'

# Drives the atlas_rb 1.2.1 linked-membership surface (the DAG overlay:
# Work.linked_members / .add_linked_member / .remove_linked_member) through
# the real HTTP boundary. The mutating calls return the Work's full list of
# linked Collection noids, so a single round-trip can assert the whole
# lifecycle.
#
# 1.2.1 also gives the rejection path teeth: a structural 422 now raises
# AtlasRb::LinkedMemberError (carrying #code) and an authorization 403 — the
# write paths are admin-only — raises AtlasRb::ForbiddenError, instead of the
# swallowed nil / parsed-hash of 1.2.0.
RSpec.describe 'Linked membership via atlas_rb', :atlas_rb_server do
  # Admin (wildcard) — linked-member writes are admin-only, so the happy-path
  # calls run as admin.
  let(:admin_nuid) { '000000004' }

  # Non-admin (edit-rights) principal for the ForbiddenError path, created on
  # the shared DB so the Puma server thread resolves it.
  let!(:editor) do
    User.find_by(nuid: '000000002') ||
      User.create!(email: 'editor-linked@example.invalid', password: SecureRandom.hex(16),
                   nuid: '000000002', name: 'Doe, Jane', role: :privileged)
  end

  let(:community) { CommunityCreator.call }
  let(:home)      { CollectionCreator.call(parent_id: community.noid) }
  let(:other)     { CollectionCreator.call(parent_id: community.noid) }
  let(:work)      { WorkCreator.call(parent_id: home.noid) }

  it 'adds, lists, and removes a linked membership through the HTTP boundary' do
    expect(AtlasRb::Work.linked_members(work.noid, nuid: admin_nuid)).to eq([])

    after_add = AtlasRb::Work.add_linked_member(work.noid, other.noid, nuid: admin_nuid)
    expect(after_add).to include(other.noid)

    listed = AtlasRb::Work.linked_members(work.noid, nuid: admin_nuid)
    expect(listed).to include(other.noid)

    after_remove = AtlasRb::Work.remove_linked_member(work.noid, other.noid, nuid: admin_nuid)
    expect(after_remove).not_to include(other.noid)
    expect(AtlasRb::Work.linked_members(work.noid, nuid: admin_nuid)).to eq([])
  end

  it 'leaves the Work\'s structural parent untouched when linking (placement, not a move)' do
    AtlasRb::Work.add_linked_member(work.noid, other.noid, nuid: admin_nuid)

    expect(Work.find(work.noid).parent.noid).to eq(home.noid)
  end

  it 'is idempotent — a repeated add yields a single linked entry' do
    AtlasRb::Work.add_linked_member(work.noid, other.noid, nuid: admin_nuid)
    after_second = AtlasRb::Work.add_linked_member(work.noid, other.noid, nuid: admin_nuid)

    expect(after_second.count(other.noid)).to eq(1)
  end

  it 'raises AtlasRb::LinkedMemberError when the target is not a Collection' do
    # 1.2.1: a structural 422 on a linked-member path surfaces as a typed
    # error carrying Atlas's discriminator, instead of the parsed hash of
    # 1.2.0. A Community target is the invalid_target_type case.
    expect do
      AtlasRb::Work.add_linked_member(work.noid, community.noid, nuid: admin_nuid)
    end.to raise_error(AtlasRb::LinkedMemberError) { |e|
      expect(e.code).to eq('invalid_target_type')
      expect(e.resource_id).to eq(work.noid)
    }

    expect(AtlasRb::Work.linked_members(work.noid, nuid: admin_nuid)).to eq([])
  end

  it 'raises AtlasRb::ForbiddenError for a non-admin caller (linking is admin-only)' do
    expect do
      AtlasRb::Work.add_linked_member(work.noid, other.noid, nuid: editor.nuid)
    end.to raise_error(AtlasRb::ForbiddenError) { |e|
      expect(e.action).to eq('link_member')
      expect(e.subject).to eq('Work')
    }

    # Refused: nothing linked, run as admin to confirm.
    expect(AtlasRb::Work.linked_members(work.noid, nuid: admin_nuid)).to eq([])
  end
end
