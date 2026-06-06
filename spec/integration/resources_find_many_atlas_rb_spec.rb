# frozen_string_literal: true

require 'rails_helper'

# atlas_rb 1.3.0 — AtlasRb::Resource.find_many wraps POST /resources/find_many
# (ResourcesController#find_many). Cerberus consumes this to resolve a set of
# NOIDs to lightweight digests in one round-trip instead of a find-per-id
# fan-out (breadcrumbs, linked-member lists, load-destination pickers).
# Exercised here end-to-end through the live server, which the request-spec
# layer can't do: it proves the gem's JSON-body serialization, Mash wrapping,
# and the drop/tombstone contract over the wire.
RSpec.describe 'Batch resource resolution via atlas_rb', :atlas_rb_server do
  let(:admin_nuid) { ATLAS_RB_SERVER_ADMIN_NUID }

  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }

  before do
    community.plain_title  = 'Root Community'
    collection.plain_title = 'Child Collection'
  end

  it 'resolves many NOIDs to digests in one call, dropping unresolvable ids' do
    digests = AtlasRb::Resource.find_many([community.noid, collection.noid, 'does-not-exist'],
                                          nuid: admin_nuid)

    expect(digests).to be_an(Array)
    by_noid = digests.index_by { |d| d['noid'] }

    # 'does-not-exist' dropped — result is shorter than the input.
    expect(by_noid.keys).to contain_exactly(community.noid, collection.noid)

    expect(by_noid[community.noid]['klass']).to eq('Community')
    expect(by_noid[community.noid]['title']).to eq('Root Community')
    expect(by_noid[community.noid]['tombstoned']).to be false
    expect(by_noid[collection.noid]['klass']).to eq('Collection')
    expect(by_noid[collection.noid]['title']).to eq('Child Collection')
  end

  it 'wraps each digest in a Mash (dot access alongside string keys)' do
    digest = AtlasRb::Resource.find_many([community.noid], nuid: admin_nuid).first

    expect(digest).to be_a(AtlasRb::Mash)
    expect(digest.noid).to eq(community.noid)
    expect(digest.title).to eq(digest['title'])
  end

  it 'keeps tombstoned resources but flags them' do
    work = WorkCreator.call(parent_id: collection.noid)
    work.tombstoned = true
    Atlas.persister.save(resource: work)

    digest = AtlasRb::Resource.find_many([work.noid], nuid: admin_nuid).first

    expect(digest['noid']).to eq(work.noid)
    expect(digest['tombstoned']).to be true
  end

  it 'returns an empty array for an empty id list' do
    expect(AtlasRb::Resource.find_many([], nuid: admin_nuid)).to eq([])
  end
end
