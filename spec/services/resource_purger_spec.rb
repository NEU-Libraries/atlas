# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ResourcePurger do
  let(:community)    { CommunityCreator.call }
  let(:collection)   { CollectionCreator.call(parent_id: community.noid) }
  let(:work)         { WorkCreator.call(parent_id: collection.noid) }
  let(:fixture_path) { Rails.root.join('spec/fixtures/files/example.png').to_s }

  # Tuple (2,2) per OCFL extension 0007 — first 4 NOID chars become directory tuples.
  def object_root_for(noid)
    Rails.root.join('tmp', 'files', noid[0..1], noid[2..3], noid)
  end

  describe '.call' do
    it 'removes the resource, its FileSets, and their Blobs from the metadata layer' do
      blob        = BlobCreator.call(path: fixture_path, work_id: work.noid, original_filename: 'example.png')
      file_sets   = work.children.select { |c| c.is_a?(FileSet) }
      blob_noids  = file_sets.flat_map { |fs| fs.children.select { |c| c.is_a?(Blob) } }.map(&:noid)

      expect(file_sets).not_to be_empty
      expect(blob_noids).to include(blob.noid)

      described_class.call(resource: work)

      expect(Work.find(work.noid)).to be_nil
      file_sets.each { |fs| expect(FileSet.find(fs.noid)).to be_nil }
      blob_noids.each { |noid| expect(Blob.find(noid)).to be_nil }
    end

    it 'removes the OCFL object holding the preserved bytes' do
      blob = BlobCreator.call(path: fixture_path, work_id: work.noid, original_filename: 'example.png')
      work.write_preservation_envelope!

      expect(object_root_for(blob.noid)).to exist
      expect(object_root_for(work.noid)).to exist

      described_class.call(resource: work)

      expect(object_root_for(blob.noid)).not_to exist
      expect(object_root_for(work.noid)).not_to exist
    end

    it 'removes every retained revision, not only the head' do
      blob = BlobCreator.call(path: fixture_path, work_id: work.noid, original_filename: 'example.png')
      Valkyrie.config.storage_adapter.upload_version(id: blob.latest_revision, file: File.open(fixture_path, 'rb'))

      expect(object_root_for(blob.noid).join('v2')).to exist

      described_class.call(resource: blob)

      expect(object_root_for(blob.noid)).not_to exist
    end

    it 'returns the NOIDs it purged, resource first' do
      BlobCreator.call(path: fixture_path, work_id: work.noid, original_filename: 'example.png')

      purged = described_class.call(resource: work)

      expect(purged.first).to eq(work.noid)
      expect(purged.length).to be > 1
    end

    it 'drops the resource from any Work that linked into it' do
      destination = CollectionCreator.call(parent_id: community.noid)
      linked      = LinkedMemberCreator.call(work: work, collection: destination)
      expect(linked.a_linked_member_of.map(&:to_s)).to include(destination.id.to_s)

      described_class.call(resource: destination)

      expect(Work.find(work.noid).a_linked_member_of.to_a).to be_empty
    end

    # An association is stored on the Work that asserts it, so purging the Work
    # it names would otherwise leave the asserter pointing at nothing.
    it 'drops the resource from any Work that asserted an association about it' do
      target   = WorkCreator.call(parent_id: collection.noid)
      asserted = WorkAssociationCreator.call(work: work, target: target, type: 'is_codebook_for')
      expect(asserted.is_codebook_for.map(&:to_s)).to include(target.id.to_s)

      described_class.call(resource: target)

      expect(Work.find(work.noid).is_codebook_for.to_a).to be_empty
    end

    it 'leaves an association that names a different Work alone' do
      target = WorkCreator.call(parent_id: collection.noid)
      other  = WorkCreator.call(parent_id: collection.noid)
      WorkAssociationCreator.call(work: work, target: target, type: 'is_codebook_for')
      WorkAssociationCreator.call(work: Work.find(work.noid), target: other, type: 'is_codebook_for')

      described_class.call(resource: target)

      expect(Work.find(work.noid).is_codebook_for.map(&:to_s)).to eq([other.id.to_s])
    end
  end

  describe 'the audit row' do
    it 'records the whole purge manifest before the resources go' do
      BlobCreator.call(path: fixture_path, work_id: work.noid, original_filename: 'example.png')
      purged = nil

      expect do
        purged = described_class.call(resource: work, actor_nuid: '000000004')
      end.to change(AuditEvent, :count).by(1)

      event = AuditEvent.last
      expect(event.action).to eq('destroy')
      expect(event.change_type).to eq('lifecycle')
      expect(event.resource_id).to eq(work.id.to_s)
      expect(event.payload['purged']).to match_array(purged)
    end

    it 'outlives the resource it describes' do
      described_class.call(resource: work, actor_nuid: '000000004')

      expect(Work.find(work.noid)).to be_nil
      expect(AuditEvent.for_resource(work.id).where(action: 'destroy')).to be_present
    end

    it 'carries the acting-as target' do
      described_class.call(resource: work, actor_nuid: '000000004', on_behalf_of_nuid: '000000005')

      expect(AuditEvent.last.on_behalf_of_nuid).to eq('000000005')
    end

    it 'writes nothing when no actor is supplied' do
      expect { described_class.call(resource: work) }.not_to change(AuditEvent, :count)
    end

    # FileSet and Blob are absent from AuditEvent::RESOURCE_TYPES, so a row of
    # their own would fail validation; their removal is recorded in the
    # ancestor's manifest instead.
    it 'writes nothing for a FileSet or a Blob' do
      blob     = BlobCreator.call(path: fixture_path, work_id: work.noid, original_filename: 'example.png')
      file_set = Blob.find(blob.noid).parent

      expect { described_class.call(resource: blob, actor_nuid: '000000004') }.not_to change(AuditEvent, :count)
      expect { described_class.call(resource: file_set, actor_nuid: '000000004') }.not_to change(AuditEvent, :count)
    end
  end
end
