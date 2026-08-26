# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BinaryVersionHistory do
  after { Atlas.persister.wipe! }

  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }
  let(:fixture)    { Rails.root.join('spec/fixtures/files/example.bin') }

  def blob_with_event(name)
    blob = BlobCreator.call(work_id: work.noid, original_filename: name, path: fixture.to_s)
    AuditEvent.create!(actor_nuid: '000000004', action: 'add_file', change_type: 'file',
                       event_source: 'controller', resource_id: work.id.to_s, resource_type: 'Work',
                       payload: { 'blob_noid' => blob.noid, 'filename' => name })
    Blob.find(blob.noid)
  end

  describe '.descriptors' do
    it 'sizes each revision from the inventory read, not a second storage lookup' do
      blob = blob_with_event('one.bin')

      expect(described_class.descriptors(blob: blob).first[:size]).to eq(File.size(fixture))
    end

    it 'uses preloaded file events in place of looking them up' do
      blob = blob_with_event('one.bin')

      descriptor = described_class.descriptors(blob: blob, file_events: []).first

      expect(descriptor[:actor_nuid]).to be_nil
    end
  end

  describe '.descriptors_for_many' do
    it 'answers the same descriptors the per-Blob read does' do
      blobs = [blob_with_event('one.bin'), blob_with_event('two.bin')]

      batched = described_class.descriptors_for_many(blobs: blobs)

      expect(batched.keys).to eq(blobs.map(&:noid))
      blobs.each { |blob| expect(batched[blob.noid]).to eq(described_class.descriptors(blob: blob)) }
    end

    it 'carries audit attribution through the batch' do
      blobs = [blob_with_event('one.bin'), blob_with_event('two.bin')]

      batched = described_class.descriptors_for_many(blobs: blobs)

      expect(batched.values.map { |d| d.first[:actor_nuid] }).to all(eq('000000004'))
    end

    it 'maps a Blob holding no bytes to an empty list' do
      empty = Atlas.persister.save(resource: Blob.new(use: Role.original_file.name))

      expect(described_class.descriptors_for_many(blobs: [empty])).to eq(empty.noid => [])
    end

    it 'answers an empty hash for no Blobs' do
      expect(described_class.descriptors_for_many(blobs: [])).to eq({})
    end
  end
end
