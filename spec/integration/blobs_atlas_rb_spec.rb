# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Blobs via atlas_rb', :atlas_rb_server do
  let(:admin_nuid) { '000000004' }

  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }
  let(:fixture)    { Rails.root.join('spec/fixtures/files/example.bin').to_s }

  it 'round-trips a Blob: multipart upload, then find by ID' do
    created = AtlasRb::Blob.create(work.noid, fixture, 'example.bin', nuid: admin_nuid)
    expect(created['id']).to be_present
    expect(created['original_filename']).to eq('example.bin')
    expect(created['size']).to eq(File.size(fixture))

    found = AtlasRb::Blob.find(created['id'], nuid: admin_nuid)
    expect(found['id']).to eq(created['id'])
    expect(found['original_filename']).to eq('example.bin')
    expect(found['size']).to eq(File.size(fixture))
  end

  it 'streams Blob content byte-for-byte through the on_data chunk handler' do
    blob = AtlasRb::Blob.create(work.noid, fixture, 'example.bin', nuid: admin_nuid)

    buffer = String.new(encoding: Encoding::ASCII_8BIT)
    headers = AtlasRb::Blob.content(blob['id'], nuid: admin_nuid) { |chunk| buffer << chunk }

    expect(buffer.bytesize).to eq(File.size(fixture))
    expect(buffer).to eq(File.binread(fixture))
    expect(headers['content-disposition']).to include('attachment')
    expect(headers['content-disposition']).to include('example.bin')
  end

  it 'destroys a Blob via HTTP' do
    blob = AtlasRb::Blob.create(work.noid, fixture, 'example.bin', nuid: admin_nuid)

    AtlasRb::Blob.destroy(blob['id'], nuid: admin_nuid)
    expect(Blob.find(blob['id'])).to be_nil
  end
end
