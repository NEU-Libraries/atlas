# frozen_string_literal: true

require 'rails_helper'

# atlas_rb — AtlasRb::Blob.ancestry / .work wrap the blob-ancestry resolver
# (BlobsController#ancestry). Backs Cerberus Impressions v2: the download path
# is keyed only by the blob id, so impression capture resolves blob -> parent
# Work off-request. Exercised end-to-end through the live server: the URL shape,
# the flat { file_set, work } return, and the .work convenience proven against
# the real endpoint.
RSpec.describe 'Blob ancestry via atlas_rb', :atlas_rb_server do
  let(:admin_nuid) { '000000004' }
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:fixture)    { Rails.root.join('spec/fixtures/files/example.bin').to_s }

  it 'resolves a content blob to its parent FileSet and Work' do
    work = WorkCreator.call(parent_id: collection.noid)
    blob = AtlasRb::Blob.create(work.noid, fixture, 'example.bin', nuid: admin_nuid)

    ancestry = AtlasRb::Blob.ancestry(blob['id'], nuid: admin_nuid)
    expect(ancestry['work']).to eq(work.noid)
    expect(ancestry['file_set']).to be_a(String).and(be_present)

    # The parent FileSet noid matches the Blob's resolved parent.
    expect(ancestry['file_set']).to eq(Blob.find(blob['id']).parent.noid)

    # .work is the convenience Cerberus's impression job uses.
    expect(AtlasRb::Blob.work(blob['id'], nuid: admin_nuid)).to eq(work.noid)
  end
end
