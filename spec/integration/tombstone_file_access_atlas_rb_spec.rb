# frozen_string_literal: true

require 'rails_helper'

# What Cerberus sees when a tombstone withholds a file: atlas_rb raises before a
# single chunk reaches the caller, and names the tombstone so a removed file and
# a suppressed Work can be answered differently. Operators are still served.
RSpec.describe 'Tombstone file access via atlas_rb', :atlas_rb_server do
  let(:admin)      { '000000004' }
  let(:collection) { CollectionCreator.call(parent_id: public_community!.noid) }
  let(:fixture)    { Rails.root.join('spec/fixtures/files/example.bin').to_s }
  let!(:editor) do
    User.create!(email: 'editor-tombstone-rb@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000063', name: 'Roe, Editor', role: :standard, groups: [])
  end
  let(:work) do
    work = WorkCreator.call(parent_id: collection.noid)
    work.publicize
    work.edit_users = [editor.nuid]
    Atlas.persister.save(resource: work)
  end
  let!(:caption) { BlobCreator.call(work_id: work.noid, original_filename: 'es.vtt', path: fixture) }

  def stream(nuid)
    chunks = []
    result = AtlasRb::Blob.content(caption.noid, nuid: nuid) { |chunk| chunks << chunk }
    [result, chunks.join]
  end

  it 'raises before a chunk for a removed file, and on its record below the operator tiers' do
    AtlasRb::Resource.tombstone(caption.parent.noid, nuid: admin)

    expect { AtlasRb::Blob.find(caption.noid, nuid: editor.nuid) }
      .to raise_error(AtlasRb::TombstonedError) { |e| expect(e.tombstoned_resource_type).to eq('FileSet') }
    expect(AtlasRb::Blob.find(caption.noid, nuid: admin).tombstoned_in_effect).to be(true)

    chunks = []
    expect { AtlasRb::Blob.content(caption.noid, nuid: editor.nuid) { |chunk| chunks << chunk } }
      .to raise_error(AtlasRb::TombstonedError) { |e| expect(e.work_suppressed?).to be(false) }
    expect(chunks).to be_empty

    result, body = stream(admin)
    expect(result[:status]).to eq(200)
    expect(body.b).to eq(File.binread(fixture))
  end

  it 'raises on the file list and the bytes of a suppressed Work' do
    suppressed = Work.find(work.noid)
    suppressed.tombstone(by: admin)
    Atlas.persister.save(resource: suppressed)

    expect { AtlasRb::Work.assets(work.noid, nuid: editor.nuid) }
      .to raise_error(AtlasRb::TombstonedError) { |e| expect(e.tombstoned_resource_id).to eq(work.noid) }
    expect { stream(editor.nuid) }
      .to raise_error(AtlasRb::TombstonedError) { |e| expect(e.work_suppressed?).to be(true) }

    expect(AtlasRb::Work.assets(work.noid, nuid: admin).map(&:noid)).to include(caption.noid)
  end

  it 'still returns a tombstoned Work from find rather than raising' do
    AtlasRb::Resource.tombstone(caption.parent.noid, nuid: admin)
    suppressed = Work.find(work.noid)
    suppressed.tombstone(by: admin)
    Atlas.persister.save(resource: suppressed)

    expect(AtlasRb::Work.find(work.noid, nuid: editor.nuid).tombstoned).to be(true)
  end
end
