# frozen_string_literal: true

require 'rails_helper'

# Drives the atlas_rb association surface (Work.associations / .associate /
# .disassociate) through the real HTTP boundary. The point of the round-trip is
# the read from BOTH ends: the edge is stored only on the asserting Work, and
# the inbound direction is derived, so a spec that only checks the asserter
# would not catch a broken inverse lookup.
#
# The write paths are admin / devolved-admin only, so the happy-path calls run
# as admin and a non-admin principal covers the ForbiddenError path.
RSpec.describe 'Work associations via atlas_rb', :atlas_rb_server do
  let(:admin_nuid) { '000000004' }

  # Non-admin (edit-rights) principal for the ForbiddenError path, created on
  # the shared DB so the Puma server thread resolves it.
  let!(:editor) do
    User.find_by(nuid: '000000002') ||
      User.create!(email: 'editor-assoc@example.invalid', password: SecureRandom.hex(16),
                   nuid: '000000002', name: 'Doe, Jane', role: :privileged)
  end

  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:codebook)   { WorkCreator.call(parent_id: collection.noid) }
  let(:dataset)    { WorkCreator.call(parent_id: collection.noid) }

  it 'asserts, reads from both ends, and retracts through the HTTP boundary' do
    empty = AtlasRb::Work.associations(codebook.noid, nuid: admin_nuid)
    expect(empty).to eq('outbound' => {}, 'inbound' => {})

    after_add = AtlasRb::Work.associate(codebook.noid, dataset.noid,
                                        type: 'is_codebook_for', nuid: admin_nuid)
    expect(after_add['outbound']).to eq('is_codebook_for' => [dataset.noid])

    # The reverse edge is never stored — the target reads it back derived.
    from_target = AtlasRb::Work.associations(dataset.noid, nuid: admin_nuid)
    expect(from_target['inbound']).to eq('is_codebook_for' => [codebook.noid])
    expect(from_target['outbound']).to eq({})

    after_remove = AtlasRb::Work.disassociate(codebook.noid, dataset.noid,
                                              type: 'is_codebook_for', nuid: admin_nuid)
    expect(after_remove['outbound']).to eq({})
    expect(AtlasRb::Work.associations(dataset.noid, nuid: admin_nuid)['inbound']).to eq({})
  end

  it 'keeps two different edges between the same pair independent' do
    AtlasRb::Work.associate(codebook.noid, dataset.noid, type: 'is_codebook_for', nuid: admin_nuid)
    both = AtlasRb::Work.associate(codebook.noid, dataset.noid, type: 'is_figure_for', nuid: admin_nuid)
    expect(both['outbound'].keys).to match_array(%w[is_codebook_for is_figure_for])

    left = AtlasRb::Work.disassociate(codebook.noid, dataset.noid,
                                      type: 'is_figure_for', nuid: admin_nuid)
    expect(left['outbound']).to eq('is_codebook_for' => [dataset.noid])
  end

  it 'raises a typed WorkAssociationError on an unknown relationship type' do
    expect {
      AtlasRb::Work.associate(codebook.noid, dataset.noid, type: 'is_sequel_to', nuid: admin_nuid)
    }.to raise_error(AtlasRb::WorkAssociationError) { |e| expect(e.code).to eq('invalid_type') }
  end

  it 'raises a typed WorkAssociationError on a non-Work target' do
    expect {
      AtlasRb::Work.associate(codebook.noid, collection.noid, type: 'is_codebook_for', nuid: admin_nuid)
    }.to raise_error(AtlasRb::WorkAssociationError) { |e| expect(e.code).to eq('invalid_target_type') }
  end

  it 'raises ForbiddenError for a non-admin principal' do
    expect {
      AtlasRb::Work.associate(codebook.noid, dataset.noid, type: 'is_codebook_for', nuid: editor.nuid)
    }.to raise_error(AtlasRb::ForbiddenError)
  end

  # Listing sits on the read floor, so an ordinary staff principal can see the
  # panel even though it cannot edit it.
  it 'lets a non-admin principal list the associations' do
    AtlasRb::Work.associate(codebook.noid, dataset.noid, type: 'is_codebook_for', nuid: admin_nuid)

    listed = AtlasRb::Work.associations(codebook.noid, nuid: editor.nuid)
    expect(listed['outbound']).to eq('is_codebook_for' => [dataset.noid])
  end
end
