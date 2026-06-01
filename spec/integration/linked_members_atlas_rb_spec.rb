# frozen_string_literal: true

require 'rails_helper'

# Drives the atlas_rb 1.2.0 linked-membership surface (the DAG overlay:
# Work.linked_members / .add_linked_member / .remove_linked_member) through
# the real HTTP boundary. All three return the Work's full list of linked
# Collection noids, so a single round-trip can assert the whole lifecycle.
RSpec.describe 'Linked membership via atlas_rb', :atlas_rb_server do
  # Admin (wildcard) — satisfies the two-sided gate (edit on the Work AND the
  # target Collection) without standing up group ACLs.
  let(:admin_nuid) { '000000004' }

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

  it 'passes a rejected link (Community target) through as the 422 error envelope' do
    # atlas_rb is a thin binding: it only raises on 409 stale_resource, so a
    # 422 flows through as the parsed error hash rather than a noid array.
    result = AtlasRb::Work.add_linked_member(work.noid, community.noid, nuid: admin_nuid)

    expect(result['error']).to eq('invalid_target_type')
    expect(AtlasRb::Work.linked_members(work.noid, nuid: admin_nuid)).to eq([])
  end
end
