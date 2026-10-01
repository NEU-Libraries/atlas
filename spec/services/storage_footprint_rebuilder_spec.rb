# frozen_string_literal: true

require 'rails_helper'

RSpec.describe StorageFootprintRebuilder do
  let(:adapter) { Valkyrie.config.storage_adapter }
  let(:fixture) { Rails.root.join('spec/fixtures/files/example.png').to_s }
  let(:work) do
    created = WorkCreator.call(parent_id: CollectionCreator.call(parent_id: CommunityCreator.call.noid).noid)
    created.in_progress = false
    Atlas.persister.save(resource: created)
  end

  before { BlobCreator.call(work_id: work.noid, path: fixture, original_filename: 'example.png') }
  after { Atlas.persister.wipe! }

  it 'restores drifted and missing rows from disk, and drops rows for absent objects' do
    StorageFootprint.where(object_key: work.noid).update_all(bytes: 1) # rubocop:disable Rails/SkipsModelValidations
    StorageFootprint.forget!(key: work.mods_blob.noid)
    StorageFootprint.add!(key: 'nosuchkey', bytes: 42)

    report = described_class.call

    expect(StorageFootprint.find(work.noid).bytes).to eq(adapter.measure_object(key: work.noid))
    expect(StorageFootprint.find(work.mods_blob.noid).bytes).to eq(adapter.measure_object(key: work.mods_blob.noid))
    expect(StorageFootprint.where(object_key: 'nosuchkey')).not_to exist
    expect(report[:removed]).to be >= 1
  end

  it "re-indexes the owner of a corrected row, so Solr shows the disk's figure" do
    StorageFootprint.where(object_key: work.noid).update_all(bytes: 1) # rubocop:disable Rails/SkipsModelValidations
    Atlas.index_adapter.persister.save(resource: Work.find(work.id))
    expected = StorageFootprintQuery.own_bytes(work) - 1 + adapter.measure_object(key: work.noid)

    described_class.call

    doc = Atlas.index_adapter.connection.get('select', params: { q: %(id:"#{work.id}"), fl: 'storage_bytes_ls' })
    expect(doc.dig('response', 'docs', 0, 'storage_bytes_ls')).to eq(expected)
  end

  # The test root also holds objects earlier examples left behind with no
  # ledger row, so only this example's objects are checked.
  it 'leaves the owners of rows that did not drift alone' do
    ours = StorageFootprint.pluck(:object_key)
    allow(StorageFootprintRecorder).to receive(:note)

    described_class.call

    ours.each { |key| expect(StorageFootprintRecorder).not_to have_received(:note).with(key) }
  end

  it 'agrees with what the write path recorded' do
    recorded = StorageFootprint.pluck(:object_key, :bytes).to_h

    described_class.call

    expect(StorageFootprint.where(object_key: recorded.keys).pluck(:object_key, :bytes).to_h).to eq(recorded)
  end
end
