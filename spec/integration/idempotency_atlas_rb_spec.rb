# frozen_string_literal: true

require 'rails_helper'

# Round-trips the idempotency-key and in_progress bindings introduced in
# atlas_rb 0.0.92 against a live Puma. Each example drives the call
# through the HTTP boundary so the client kwarg → header → IdempotentCreate
# concern → IdempotencyKey row path is exercised end-to-end.
#
# The IdempotentCreate concern scopes keys to the acting user. With an
# empty ATLAS_TOKEN (the harness default) every request lands as the
# guest user, so the spec commits a guest row in before(:all) — that
# block runs outside the per-example transaction, so the row is visible
# to the Puma thread (which holds a separate AR connection).
RSpec.describe 'Idempotency + in_progress bindings via atlas_rb', :atlas_rb_server do
  # before(:all) commits outside the per-example transaction, so the row
  # is visible to the Puma thread. after(:all) tears it down only if we
  # were the ones who seeded it — users_spec.rb's `let!(:guest)` does a
  # raw User.create! and breaks if a guest@example.com row is left behind.
  before(:all) do
    @seeded_guest =
      if User.find_by_role(:guest)
        nil
      else
        User.create!(email: 'guest@example.com',
                     password: SecureRandom.hex(16),
                     role: :guest)
      end
  end

  after(:all) do
    next unless @seeded_guest

    IdempotencyKey.where(user_id: @seeded_guest.id).delete_all
    @seeded_guest.destroy
  end

  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }

  describe 'AtlasRb::Work.create' do
    it 'returns the originally-created Work on replay with the same key' do
      key   = SecureRandom.uuid
      first = AtlasRb::Work.create(collection.noid, idempotency_key: key)

      replay = AtlasRb::Work.create(collection.noid, idempotency_key: key)

      expect(replay['id']).to eq(first['id'])
      expect(Atlas.query.find_all_of_model(model: Work).size).to eq(1)
    end

    it 'creates fresh Works when no key is supplied' do
      a = AtlasRb::Work.create(collection.noid)
      b = AtlasRb::Work.create(collection.noid)

      expect(b['id']).not_to eq(a['id'])
    end

    it 'creates fresh Works when keys differ' do
      a = AtlasRb::Work.create(collection.noid, idempotency_key: SecureRandom.uuid)
      b = AtlasRb::Work.create(collection.noid, idempotency_key: SecureRandom.uuid)

      expect(b['id']).not_to eq(a['id'])
    end

    it 'returns the tombstoned payload on replay of a tombstoned Work (410 with body)' do
      key   = SecureRandom.uuid
      first = AtlasRb::Work.create(collection.noid, idempotency_key: key)
      AtlasRb::Work.tombstone(first['id'], nuid: '000000004')

      replay = AtlasRb::Work.create(collection.noid, idempotency_key: key)

      expect(replay['id']).to eq(first['id'])
      expect(replay['tombstoned']).to be true
    end
  end

  describe 'AtlasRb::FileSet.create' do
    let(:work) { WorkCreator.call(parent_id: collection.noid) }

    it 'returns the originally-created FileSet on replay with the same key' do
      key   = SecureRandom.uuid
      first = AtlasRb::FileSet.create(work.noid, 'generic', idempotency_key: key)

      replay = AtlasRb::FileSet.create(work.noid, 'generic', idempotency_key: key)

      expect(replay['id']).to eq(first['id'])
    end

    it 'creates fresh FileSets when no key is supplied' do
      a = AtlasRb::FileSet.create(work.noid, 'generic')
      b = AtlasRb::FileSet.create(work.noid, 'generic')

      expect(b['id']).not_to eq(a['id'])
    end
  end

  describe 'AtlasRb::Blob.create' do
    let(:work)    { WorkCreator.call(parent_id: collection.noid) }
    let(:fixture) { Rails.root.join('spec/fixtures/files/example.bin').to_s }

    it 'returns the originally-created Blob on replay with the same key' do
      key   = SecureRandom.uuid
      first = AtlasRb::Blob.create(work.noid, fixture, 'example.bin',
                                   idempotency_key: key)

      replay = AtlasRb::Blob.create(work.noid, fixture, 'example.bin',
                                    idempotency_key: key)

      expect(replay['id']).to eq(first['id'])
    end

    it 'creates fresh Blobs when no key is supplied' do
      a = AtlasRb::Blob.create(work.noid, fixture, 'example.bin')
      b = AtlasRb::Blob.create(work.noid, fixture, 'example.bin')

      expect(b['id']).not_to eq(a['id'])
    end
  end

  describe 'AtlasRb::Work.complete' do
    it 'marks a freshly-created Work as in_progress: true by default' do
      created = AtlasRb::Work.create(collection.noid)

      expect(AtlasRb::Work.find(created['id'])['in_progress']).to be true
    end

    it 'flips in_progress to false' do
      created = AtlasRb::Work.create(collection.noid)

      AtlasRb::Work.complete(created['id'])

      expect(AtlasRb::Work.find(created['id'])['in_progress']).to be false
    end

    it 'is idempotent: replaying complete on a complete Work stays complete' do
      created = AtlasRb::Work.create(collection.noid)
      AtlasRb::Work.complete(created['id'])

      response = AtlasRb::Work.complete(created['id'])

      expect(response.status).to eq(200)
      expect(AtlasRb::Work.find(created['id'])['in_progress']).to be false
    end
  end

  describe 'AtlasRb::Work.list' do
    it 'returns only in-progress Works when in_progress: true' do
      in_p = AtlasRb::Work.create(collection.noid)
      done = AtlasRb::Work.create(collection.noid)
      AtlasRb::Work.complete(done['id'])

      ids = AtlasRb::Work.list(in_progress: true)['works'].map { |w| w['work']['id'] }

      expect(ids).to include(in_p['id'])
      expect(ids).not_to include(done['id'])
    end

    it 'returns only completed Works when in_progress: false' do
      in_p = AtlasRb::Work.create(collection.noid)
      done = AtlasRb::Work.create(collection.noid)
      AtlasRb::Work.complete(done['id'])

      ids = AtlasRb::Work.list(in_progress: false)['works'].map { |w| w['work']['id'] }

      expect(ids).to include(done['id'])
      expect(ids).not_to include(in_p['id'])
    end

    it 'returns every Work when no filter is supplied' do
      in_p = AtlasRb::Work.create(collection.noid)
      done = AtlasRb::Work.create(collection.noid)
      AtlasRb::Work.complete(done['id'])

      ids = AtlasRb::Work.list['works'].map { |w| w['work']['id'] }

      expect(ids).to include(in_p['id'], done['id'])
    end
  end
end
