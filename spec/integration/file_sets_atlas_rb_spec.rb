# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'FileSets via atlas_rb', :atlas_rb_server do
  let(:admin_nuid) { '000000004' }

  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  it 'round-trips a FileSet through the HTTP boundary' do
    created = AtlasRb::FileSet.create(work.noid, 'generic', nuid: admin_nuid)
    expect(created['id']).to be_present

    found = AtlasRb::FileSet.find(created['id'], nuid: admin_nuid)
    expect(found['id']).to eq(created['id'])
  end

  it 'creates an ordered (multipage) FileSet with a position' do
    created = AtlasRb::FileSet.create(work.noid, 'image', position: 2, nuid: admin_nuid)

    expect(created['position']).to eq(2)
    expect(FileSet.find(created['id']).position).to eq(2)
  end

  it 'leaves position nil when the kwarg is omitted' do
    created = AtlasRb::FileSet.create(work.noid, 'generic', nuid: admin_nuid)
    expect(created['position']).to be_nil
  end

  it 'attaches binary content to a FileSet via multipart update' do
    file_set = FileSetCreator.call(work_id: work.noid, classification: Classification.generic)

    AtlasRb::FileSet.update(file_set.noid, Rails.root.join('spec/fixtures/files/example.bin').to_s, nuid: admin_nuid)

    expect(FileSet.find(file_set.noid).children.size).to be >= 1
  end

  it 'destroys a FileSet via HTTP' do
    file_set = FileSetCreator.call(work_id: work.noid, classification: Classification.generic)

    AtlasRb::FileSet.destroy(file_set.noid, nuid: admin_nuid)
    expect(FileSet.find(file_set.noid)).to be_nil
  end
end
