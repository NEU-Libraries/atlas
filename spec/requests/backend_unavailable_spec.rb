# frozen_string_literal: true

require 'rails_helper'

# A dependency outage answers a typed 503, so a client can tell it from a bug.
# The handlers live in app/controllers/concerns/backend_unavailable.rb.
RSpec.describe 'Backend unavailable', type: :request do
  def expect_backend_unavailable(dependency)
    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body).to include('error' => 'backend_unavailable', 'dependency' => dependency)
    expect(response.headers['Retry-After']).to eq(BackendUnavailable::RETRY_AFTER.to_s)
  end

  def solr_context
    { uri: URI('http://solr:8983/solr/blacklight-test/select'), method: :get, params: {} }
  end

  describe 'the database' do
    it 'answers 503 when no connection can be made, even before auth resolves' do
      allow(User).to receive(:resolve_account)
        .and_raise(ActiveRecord::ConnectionNotEstablished, 'connection to server at "10.0.0.5" failed')

      get '/maintenance'

      expect_backend_unavailable('database')
      expect(response.body).not_to include('10.0.0.5')
    end

    it 'answers 503 when the connection drops mid-query' do
      allow(MaintenanceMode).to receive(:current).and_raise(ActiveRecord::ConnectionFailed, 'server closed the connection')

      get '/maintenance'

      expect_backend_unavailable('database')
    end
  end

  describe 'the index' do
    it 'answers 503 when Solr refuses the connection' do
      allow(Atlas.index_adapter).to receive(:connection).and_return(RSolr.connect(url: 'http://localhost:1/solr/absent'))

      get '/resources/search', params: { q: 'anything' }

      expect_backend_unavailable('index')
    end

    it 'answers 503 when Solr itself answers 5xx' do
      allow(SearchQuery).to receive(:call)
        .and_raise(RSolr::Error::Http.new(solr_context, { status: 503, body: +'core is loading' }))

      get '/resources/search', params: { q: 'anything' }

      expect_backend_unavailable('index')
    end

    it 'leaves a 4xx from Solr as the error it is, because Atlas built the query' do
      allow(SearchQuery).to receive(:call)
        .and_raise(RSolr::Error::Http.new(solr_context, { status: 400, body: +'undefined field' }))

      expect { get '/resources/search', params: { q: 'anything' } }.to raise_error(RSolr::Error::Http)
    end
  end

  describe 'the storage' do
    let(:community)  { CommunityCreator.call }
    let(:collection) { CollectionCreator.call(parent_id: community.noid) }
    let(:work)       { WorkCreator.call(parent_id: collection.noid) }
    let(:fixture)    { Rails.root.join('spec/fixtures/files/example.bin') }
    let(:blob) { BlobCreator.call(work_id: work.noid, original_filename: 'example.bin', path: fixture.to_s) }

    # The volume is gone: the root's path is an empty directory.
    it 'answers 503 rather than 404 when the root holding a binary is not provisioned' do
      noid = blob.noid
      FileUtils.rm_rf(Dir.glob("#{TestStorage.root}/*"))

      get "/files/#{noid}/content"

      expect_backend_unavailable('storage')
    end

    it 'answers 503 on a filesystem fault' do
      noid = blob.noid
      allow(Valkyrie.config.storage_adapter).to receive(:find_by).and_raise(Errno::EIO)

      get "/files/#{noid}/content"

      expect_backend_unavailable('storage')
    end
  end
end
