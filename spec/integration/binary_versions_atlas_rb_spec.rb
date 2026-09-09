# frozen_string_literal: true

require 'rails_helper'

# atlas_rb — AtlasRb::Blob.versions / version_content / rollback (and the
# idempotency_key thread on update) wrap the binary version-read surface
# (BlobsController#versions / version_content / rollback). The counterpart to
# the MODS-versions integration spec. Cerberus consumes these for the "Replace
# a file" history/recovery surface. Exercised here end-to-end through the live
# server: URL shapes, header threading, and the distinct return shapes (Mash
# envelope, streamed bytes, unwrapped blob) proven against the real endpoints.
RSpec.describe 'Binary version history via atlas_rb', :atlas_rb_server do
  # Admin (wildcard): the versions list is admin-gated (audit-derived
  # attribution), and the HTTP create/replace need an authenticated actor to
  # emit the correlated add_file / replace_file AuditEvents.
  let(:admin_nuid) { '000000004' }

  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:fixture_a)  { Rails.root.join('spec/fixtures/files/example.bin').to_s }
  let(:fixture_b)  { Rails.root.join('spec/fixtures/files/example.png').to_s }

  it 'lists versions, streams a prior version’s bytes, and rolls back non-destructively' do
    work = WorkCreator.call(parent_id: collection.noid)
    blob = AtlasRb::Blob.create(work.noid, fixture_a, 'example.bin', nuid: admin_nuid)
    AtlasRb::Blob.update(blob['id'], fixture_b, nuid: admin_nuid) # current is now fixture_b

    envelope = AtlasRb::Blob.versions(blob['id'], nuid: admin_nuid)
    expect(envelope['blob_id']).to eq(blob['id'])
    expect(envelope['versions'].length).to eq(2) # seed + one replace

    newest = envelope['versions'].first
    expect(newest['version_id']).to match(/\Av\d+\z/)
    expect(newest['actor_nuid']).to eq(admin_nuid)
    expect(newest['digest']).to match(/\Asha512:[0-9a-f]+\z/)
    # Every row carries its own recorded timestamp and fixity digest, not only
    # the head one: the consumer renders a When and a Fixity cell per row.
    expect(envelope['versions'].pluck('created')).to all(be_present)
    expect(envelope['versions'].pluck('digest')).to all(match(/\Asha512:[0-9a-f]+\z/))
    seed_label = envelope['versions'].last['version_id']

    # Streaming the seed version yields the original bytes, byte-for-byte.
    chunks = []
    streamed = AtlasRb::Blob.version_content(blob['id'], seed_label, nuid: admin_nuid) { |c| chunks << c }
    expect(chunks.join.b).to eq(File.binread(fixture_a))
    # The status rides back with the headers because a streamed read cannot
    # raise: a caller writing these chunks to a download has to be able to tell
    # them from an error body.
    expect(streamed[:status]).to eq(200)
    expect(streamed[:headers]).to be_a(Hash)

    # Rollback reinstates the seed bytes as a new revision (NOID stable).
    rolled = AtlasRb::Blob.rollback(blob['id'], seed_label, nuid: admin_nuid)
    expect(rolled['id']).to eq(blob['id'])

    after = AtlasRb::Blob.versions(blob['id'], nuid: admin_nuid)
    expect(after['versions'].length).to eq(3) # grew by one — non-destructive

    current = []
    AtlasRb::Blob.content(blob['id'], nuid: admin_nuid) { |c| current << c }
    expect(current.join.b).to eq(File.binread(fixture_a))
  end

  # The batch read exists to collapse a versions-per-noid fan-out, so what has
  # to hold end-to-end is that one call answers the same envelopes the per-Blob
  # calls do — including the audit attribution, which is the part the batch
  # resolves differently (one ledger read for every Blob's parent Work).
  it 'answers many Blobs’ histories in one call, matching the per-Blob reads' do
    work  = WorkCreator.call(parent_id: collection.noid)
    first = AtlasRb::Blob.create(work.noid, fixture_a, 'first.bin', nuid: admin_nuid)
    other = WorkCreator.call(parent_id: collection.noid)
    second = AtlasRb::Blob.create(other.noid, fixture_b, 'second.png', nuid: admin_nuid)
    AtlasRb::Blob.update(second['id'], fixture_a, nuid: admin_nuid)

    ids = [first['id'], second['id']]
    by_id = AtlasRb::Blob.find_many_versions(ids + ['does-not-exist'], nuid: admin_nuid)
                         .index_by { |envelope| envelope['blob_id'] }

    expect(by_id.keys).to match_array(ids)
    expect(by_id[second['id']]['versions'].length).to eq(2)
    expect(by_id[second['id']]['versions'].first['revision']).to eq(2)
    expect(by_id.values.map { |e| e['versions'].first['actor_nuid'] }).to all(eq(admin_nuid))

    ids.each do |id|
      expect(by_id[id].to_h).to eq(AtlasRb::Blob.versions(id, nuid: admin_nuid).to_h)
    end
  end

  it 'deduplicates a double-submitted replace sharing an idempotency_key' do
    work = WorkCreator.call(parent_id: collection.noid)
    blob = AtlasRb::Blob.create(work.noid, fixture_a, 'example.bin', nuid: admin_nuid)
    key  = SecureRandom.uuid

    AtlasRb::Blob.update(blob['id'], fixture_b, idempotency_key: key, nuid: admin_nuid)
    after_first = AtlasRb::Blob.versions(blob['id'], nuid: admin_nuid)['versions'].length

    AtlasRb::Blob.update(blob['id'], fixture_b, idempotency_key: key, nuid: admin_nuid)
    after_second = AtlasRb::Blob.versions(blob['id'], nuid: admin_nuid)['versions'].length

    expect(after_second).to eq(after_first) # one new version, not two
  end
end
