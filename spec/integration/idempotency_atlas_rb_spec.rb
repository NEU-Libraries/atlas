# frozen_string_literal: true

require 'rails_helper'

# Round-trips the idempotency-key and in_progress bindings introduced in
# atlas_rb 0.0.92 against a live Puma. Each example drives the call
# through the HTTP boundary so the client kwarg → header → IdempotentCreate
# concern → IdempotencyKey row path is exercised end-to-end.
#
# The IdempotentCreate concern scopes keys to the acting user, so every
# call below threads `nuid: admin_nuid` explicitly — the idempotency rows
# are written and matched against the admin user that the harness seeds.
RSpec.describe 'Idempotency + in_progress bindings via atlas_rb', :atlas_rb_server do
  let(:admin_nuid) { '000000004' }

  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }

  describe 'AtlasRb::Work.create' do
    it 'returns the originally-created Work on replay with the same key' do
      key   = SecureRandom.uuid
      first = AtlasRb::Work.create(collection.noid, idempotency_key: key, nuid: admin_nuid)

      replay = AtlasRb::Work.create(collection.noid, idempotency_key: key, nuid: admin_nuid)

      expect(replay['id']).to eq(first['id'])
      expect(Atlas.query.find_all_of_model(model: Work).size).to eq(1)
    end

    it 'creates fresh Works when no key is supplied' do
      a = AtlasRb::Work.create(collection.noid, nuid: admin_nuid)
      b = AtlasRb::Work.create(collection.noid, nuid: admin_nuid)

      expect(b['id']).not_to eq(a['id'])
    end

    it 'creates fresh Works when keys differ' do
      a = AtlasRb::Work.create(collection.noid, idempotency_key: SecureRandom.uuid, nuid: admin_nuid)
      b = AtlasRb::Work.create(collection.noid, idempotency_key: SecureRandom.uuid, nuid: admin_nuid)

      expect(b['id']).not_to eq(a['id'])
    end

    it 'returns the tombstoned payload on replay of a tombstoned Work (410 with body)' do
      key   = SecureRandom.uuid
      first = AtlasRb::Work.create(collection.noid, idempotency_key: key, nuid: admin_nuid)
      AtlasRb::Work.tombstone(first['id'], nuid: admin_nuid)

      replay = AtlasRb::Work.create(collection.noid, idempotency_key: key, nuid: admin_nuid)

      expect(replay['id']).to eq(first['id'])
      expect(replay['tombstoned']).to be true
    end
  end

  describe 'AtlasRb::FileSet.create' do
    let(:work) { WorkCreator.call(parent_id: collection.noid) }

    it 'returns the originally-created FileSet on replay with the same key' do
      key   = SecureRandom.uuid
      first = AtlasRb::FileSet.create(work.noid, 'generic', idempotency_key: key, nuid: admin_nuid)

      replay = AtlasRb::FileSet.create(work.noid, 'generic', idempotency_key: key, nuid: admin_nuid)

      expect(replay['id']).to eq(first['id'])
    end

    it 'creates fresh FileSets when no key is supplied' do
      a = AtlasRb::FileSet.create(work.noid, 'generic', nuid: admin_nuid)
      b = AtlasRb::FileSet.create(work.noid, 'generic', nuid: admin_nuid)

      expect(b['id']).not_to eq(a['id'])
    end
  end

  # atlas_rb 1.6.0 — the binary attach (PATCH /file_sets/{id}) is now idempotent
  # too, so a re-run of the migration's attach phase doesn't recopy bytes.
  describe 'AtlasRb::FileSet.update (binary attach)' do
    let(:work)    { WorkCreator.call(parent_id: collection.noid) }
    let(:fixture) { Rails.root.join('spec/fixtures/files/example.bin').to_s }

    it 'returns the FileSet without recopying bytes on replay with the same key' do
      file_set = FileSetCreator.call(work_id: work.noid, classification: Classification.generic)
      key      = SecureRandom.uuid

      first  = AtlasRb::FileSet.update(file_set.noid, fixture, idempotency_key: key, nuid: admin_nuid)
      replay = AtlasRb::FileSet.update(file_set.noid, fixture, idempotency_key: key, nuid: admin_nuid)

      expect(replay['file_set']['id']).to eq(first['file_set']['id'])
      expect(FileSet.find(file_set.noid).content_files.size).to eq(1)
    end
  end

  describe 'AtlasRb::Blob.create' do
    let(:work)    { WorkCreator.call(parent_id: collection.noid) }
    let(:fixture) { Rails.root.join('spec/fixtures/files/example.bin').to_s }

    it 'returns the originally-created Blob on replay with the same key' do
      key   = SecureRandom.uuid
      first = AtlasRb::Blob.create(work.noid, fixture, 'example.bin',
                                   idempotency_key: key, nuid: admin_nuid)

      replay = AtlasRb::Blob.create(work.noid, fixture, 'example.bin',
                                    idempotency_key: key, nuid: admin_nuid)

      expect(replay['id']).to eq(first['id'])
    end

    it 'creates fresh Blobs when no key is supplied' do
      a = AtlasRb::Blob.create(work.noid, fixture, 'example.bin', nuid: admin_nuid)
      b = AtlasRb::Blob.create(work.noid, fixture, 'example.bin', nuid: admin_nuid)

      expect(b['id']).not_to eq(a['id'])
    end
  end

  # The XML batch loader's shape: one manifest row carries one key, and passes
  # it to the Work it creates and again to that Work's Blob. The key lookup is
  # scoped by resource class, so both are legal — but while the unique index
  # covered only (user, key), the Blob's key could neither replay nor record.
  # It 422'd *after* the Blob had been persisted, so the job died before
  # Work.complete and every batch-created Work stayed in_progress forever,
  # which the edit filter reads as "not editable".
  describe 'one key across a Work and its Blob (the batch-loader sequence)' do
    let(:fixture) { Rails.root.join('spec/fixtures/files/example.bin').to_s }

    it 'creates both and leaves the Work completable' do
      key  = SecureRandom.uuid
      work = AtlasRb::Work.create(collection.noid, idempotency_key: key, nuid: admin_nuid)

      blob = AtlasRb::Blob.create(work['id'], fixture, 'example.bin',
                                  idempotency_key: key, nuid: admin_nuid)
      AtlasRb::Work.complete(work['id'], nuid: admin_nuid)

      expect(blob['id']).to be_present
      expect(AtlasRb::Work.find(work['id'], nuid: admin_nuid)['in_progress']).to be false
    end

    it 'records a row per class, so each replays independently' do
      key  = SecureRandom.uuid
      work = AtlasRb::Work.create(collection.noid, idempotency_key: key, nuid: admin_nuid)
      blob = AtlasRb::Blob.create(work['id'], fixture, 'example.bin',
                                  idempotency_key: key, nuid: admin_nuid)

      work_replay = AtlasRb::Work.create(collection.noid, idempotency_key: key, nuid: admin_nuid)
      blob_replay = AtlasRb::Blob.create(work['id'], fixture, 'example.bin',
                                         idempotency_key: key, nuid: admin_nuid)

      expect(work_replay['id']).to eq(work['id'])
      expect(blob_replay['id']).to eq(blob['id'])
      expect(IdempotencyKey.where(key: key).pluck(:resource_type)).to contain_exactly('Work', 'Blob')
    end

    it 'reaches a FileSet under the same key too' do
      key  = SecureRandom.uuid
      work = AtlasRb::Work.create(collection.noid, idempotency_key: key, nuid: admin_nuid)

      file_set = AtlasRb::FileSet.create(work['id'], 'image', idempotency_key: key, nuid: admin_nuid)

      expect(file_set['id']).to be_present
      expect(IdempotencyKey.where(key: key).pluck(:resource_type)).to contain_exactly('Work', 'FileSet')
    end
  end

  describe 'AtlasRb::Work.complete' do
    it 'marks a freshly-created Work as in_progress: true by default' do
      created = AtlasRb::Work.create(collection.noid, nuid: admin_nuid)

      expect(AtlasRb::Work.find(created['id'], nuid: admin_nuid)['in_progress']).to be true
    end

    it 'flips in_progress to false' do
      created = AtlasRb::Work.create(collection.noid, nuid: admin_nuid)

      AtlasRb::Work.complete(created['id'], nuid: admin_nuid)

      expect(AtlasRb::Work.find(created['id'], nuid: admin_nuid)['in_progress']).to be false
    end

    it 'is idempotent: replaying complete on a complete Work stays complete' do
      created = AtlasRb::Work.create(collection.noid, nuid: admin_nuid)
      AtlasRb::Work.complete(created['id'], nuid: admin_nuid)

      response = AtlasRb::Work.complete(created['id'], nuid: admin_nuid)

      expect(response.status).to eq(200)
      expect(AtlasRb::Work.find(created['id'], nuid: admin_nuid)['in_progress']).to be false
    end
  end

  describe 'AtlasRb::Work.list' do
    it 'returns only in-progress Works when in_progress: true' do
      in_p = AtlasRb::Work.create(collection.noid, nuid: admin_nuid)
      done = AtlasRb::Work.create(collection.noid, nuid: admin_nuid)
      AtlasRb::Work.complete(done['id'], nuid: admin_nuid)

      ids = AtlasRb::Work.list(in_progress: true, nuid: admin_nuid)['works'].pluck('id')

      expect(ids).to include(in_p['id'])
      expect(ids).not_to include(done['id'])
    end

    it 'returns only completed Works when in_progress: false' do
      in_p = AtlasRb::Work.create(collection.noid, nuid: admin_nuid)
      done = AtlasRb::Work.create(collection.noid, nuid: admin_nuid)
      AtlasRb::Work.complete(done['id'], nuid: admin_nuid)

      ids = AtlasRb::Work.list(in_progress: false, nuid: admin_nuid)['works'].pluck('id')

      expect(ids).to include(done['id'])
      expect(ids).not_to include(in_p['id'])
    end

    it 'returns every Work when no filter is supplied' do
      in_p = AtlasRb::Work.create(collection.noid, nuid: admin_nuid)
      done = AtlasRb::Work.create(collection.noid, nuid: admin_nuid)
      AtlasRb::Work.complete(done['id'], nuid: admin_nuid)

      ids = AtlasRb::Work.list(nuid: admin_nuid)['works'].pluck('id')

      expect(ids).to include(in_p['id'], done['id'])
    end
  end
end
