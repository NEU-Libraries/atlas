# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'Health', type: :request do
  before do
    FileUtils.mkdir_p(TestStorage.root)
    SystemHealth.reset!
  end

  after { SystemHealth.reset! }

  path '/health' do
    get 'Report whether Atlas can reach its dependencies' do
      tags 'Health'
      operationId 'health_show'
      produces 'application/json'
      description <<~D
        Readiness. Probes Postgres, Solr, the OCFL storage roots and the Redis
        cache, and names each one `ok` or `unavailable`. Unauthenticated, so the
        body carries no host names, versions or error text; the per-dependency
        detail goes to Atlas's log.

        Answers `503` when the database, the index or the storage is
        unavailable, and `200` otherwise. A cache outage alone leaves it `200`
        with `status: "degraded"`, because reads fall back to rendering. The
        result is memoized for five seconds per process, so polling it costs
        nothing.

        `GET /up` is the separate liveness route: it answers `200` once the app
        has booted and touches no dependency.
      D

      response '200', 'every required dependency answers' do
        schema '$ref' => '#/components/schemas/Health'
        run_test! do |response|
          expect(response.parsed_body).to include('status' => 'ok', 'database' => 'ok',
                                                  'index' => 'ok', 'storage' => 'ok')
        end
      end

      response '503', 'a required dependency is unavailable' do
        schema '$ref' => '#/components/schemas/Health'
        before { allow(SolrCore).to receive(:url).and_return('http://localhost:1/solr/absent') }

        run_test! do |response|
          expect(response.parsed_body).to include('status' => 'degraded', 'index' => 'unavailable',
                                                  'database' => 'ok')
        end
      end
    end
  end
end

RSpec.describe 'Health routes', type: :request do
  before do
    FileUtils.mkdir_p(TestStorage.root)
    SystemHealth.reset!
  end

  after { SystemHealth.reset! }

  it 'answers GET /health with no credential at all' do
    get '/health', headers: { 'Authorization' => '' }
    expect(response).to have_http_status(:ok)
  end

  it 'answers GET /health while the database is unreachable, and says so' do
    allow(ActiveRecord::Base.connection_pool).to receive(:with_connection)
      .and_raise(ActiveRecord::ConnectionNotEstablished, 'connection to server at "db" failed')

    get '/health'

    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body).to include('status' => 'unavailable', 'database' => 'unavailable')
    expect(response.body).not_to include('failed')
  end

  it 'answers GET /up without touching a dependency' do
    allow(ActiveRecord::Base).to receive(:connection_pool).and_raise('must not be reached')

    get '/up'

    expect(response).to have_http_status(:ok)
  end
end
