# frozen_string_literal: true

require 'rails_helper'

# mods_updated_at_dtsi moves when a Work's MODS XML changes, and for nothing
# else. See docs/solr-indexing.md.
RSpec.describe 'The MODS edit date on a Work', type: :request do
  let(:collection) { CollectionCreator.call(parent_id: public_community!.noid) }
  let(:mods)       { Rails.root.join('spec/fixtures/files/work-mods.xml') }
  let(:now)        { Time.utc(2026, 1, 5, 9, 0, 0) }

  # The adapter took its clock at boot, so travel_to cannot reach it.
  before do
    clock = -> { now }
    allow(Valkyrie.config.storage_adapter).to receive(:clock).and_return(clock)
  end

  after { Atlas.persister.wipe! }

  def edited_at(resource)
    Atlas.index_adapter.connection.get(
      'select', params: { q: %(id:"#{resource.id}"), fl: 'mods_updated_at_dtsi' }
    ).dig('response', 'docs').first&.fetch('mods_updated_at_dtsi', nil)
  end

  def put_mods(work, path = mods)
    put "/resources/#{work.noid}/mods", params: { binary: Rack::Test::UploadedFile.new(path) }
    expect(response).to have_http_status(:ok)
  end

  def at(time)
    allow(Valkyrie.config.storage_adapter).to receive(:clock).and_return(-> { time })
  end

  it 'starts at the MODS written when the Work is created' do
    work = WorkCreator.call(parent_id: collection.noid)
    expect(edited_at(work)).to eq('2026-01-05T09:00:00Z')
  end

  it 'moves when the MODS changes' do
    work = WorkCreator.call(parent_id: collection.noid)
    at(Time.utc(2026, 2, 1, 12, 0, 0))
    put_mods(work)

    expect(edited_at(work)).to eq('2026-02-01T12:00:00Z')
  end

  it 'stays put when identical MODS is uploaded again' do
    work = WorkCreator.call(parent_id: collection.noid)
    at(Time.utc(2026, 2, 1, 12, 0, 0))
    put_mods(work)
    at(Time.utc(2026, 3, 1, 12, 0, 0))
    put_mods(work)

    expect(edited_at(work)).to eq('2026-02-01T12:00:00Z')
  end

  it 'stays put through other writes, a reindex and a reproject' do
    work = WorkCreator.call(parent_id: collection.noid)
    at(Time.utc(2026, 4, 1, 12, 0, 0))

    patch "/resources/#{work.noid}/permissions", params:  { permissions: { read: ['public'] } }.to_json,
                                                 headers: { 'CONTENT_TYPE' => 'application/json' }
    expect(response).to have_http_status(:ok)
    post "/works/#{work.noid}/incomplete", params:  { reason: 'checking' }.to_json,
                                           headers: { 'CONTENT_TYPE' => 'application/json' }
    reloaded = Work.find(work.noid)
    reloaded.mods_json = reloaded.mods_xml
    Atlas.reindex(reloaded)

    expect(edited_at(work)).to eq('2026-01-05T09:00:00Z')
  end

  it 'is not projected onto a container' do
    expect(edited_at(collection)).to be_nil
  end
end
