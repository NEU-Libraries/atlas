# frozen_string_literal: true

require 'rails_helper'

RSpec.describe StorageFootprintRecorder do
  let(:fixture) { Rails.root.join('spec/fixtures/files/example.png').to_s }
  let(:work) do
    created = WorkCreator.call(parent_id: CollectionCreator.call(parent_id: CommunityCreator.call.noid).noid)
    created.in_progress = false
    Atlas.persister.save(resource: created)
  end

  after { Atlas.persister.wipe! }

  def attach(name)
    BlobCreator.call(work_id: work.noid, path: fixture, original_filename: name)
  end

  it 'resolves a Blob, its FileSet and the Work itself to the Work' do
    blob = attach('a.png')
    file_set = Atlas.query.find_parents(resource: blob).first

    expect([blob, file_set, work].map { |r| described_class.owner_of(r.noid)&.id }).to all(eq(work.id))
  end

  it "resolves a container's MODS Blob to the container" do
    collection = Collection.find(work.a_member_of)

    expect(described_class.owner_of(collection.mods_blob.noid)&.id).to eq(collection.id)
  end

  it 're-indexes each touched owner once per batch, however many versions it writes' do
    work
    allow(described_class).to receive(:index).and_call_original

    described_class.batch do
      attach('a.png')
      attach('b.png')
    end

    expect(described_class).to have_received(:index).with(have_attributes(id: work.id)).once
  end

  it 're-indexes at once outside a batch' do
    blob = attach('a.png')
    allow(described_class).to receive(:index).and_call_original

    described_class.note(blob.noid)

    expect(described_class).to have_received(:index).with(have_attributes(id: work.id)).once
  end

  it 'does not re-index a Work that is still in progress' do
    ingesting = WorkCreator.call(parent_id: Collection.find(work.a_member_of).noid)
    allow(Atlas.index_adapter.persister).to receive(:save).and_call_original

    described_class.batch { BlobCreator.call(work_id: ingesting.noid, path: fixture, original_filename: 'p.png') }

    expect(Atlas.index_adapter.persister).not_to have_received(:save).with(resource: have_attributes(id: ingesting.id))
  end

  it 'does not fail the batch when the re-index fails' do
    work
    allow(described_class).to receive(:index).and_raise(RuntimeError, 'solr down')

    expect { described_class.batch { attach('a.png') } }.not_to raise_error
  end
end
