# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'Metrics', type: :request do
  before do
    RequestLatency.clear!
    RequestLatency.resume!
  end

  after { RequestLatency.clear! }

  path '/metrics/latency' do
    get "Report Atlas's own request latency" do
      tags 'Metrics'
      operationId 'metrics_latency'
      produces 'application/json'
      parameter name: :minutes, in: :query, type: :integer, required: false,
                description: 'Window in minutes, 1 to 120. Default 60.'
      description <<~D
        How long Atlas took to serve its own requests over a recent window,
        measured from when Rails dispatches the action until it returns. It
        does not include time a request spent queued before Puma handed it to
        Rails, nor the network. A client that also times its calls can subtract
        to see how much of its wait was its own.

        Restricted to admins and the system principal.

        The percentiles are interpolated from a histogram with edges at 5, 10,
        25, 50, 100, 250, 500, 1000, 2500, 5000 and 10000 ms, so they are
        approximate. GET /up, GET /health and this endpoint are not counted.

        Answers `503` with `error: "backend_unavailable"` and
        `dependency: "cache"` when Redis, which holds the figures, does not
        answer.
      D

      response '200', 'latency for the window' do
        schema '$ref' => '#/components/schemas/Latency'
        let(:minutes) { 30 }
        before do
          RequestLatency.record(30, action: 'works#show')
          RequestLatency.record(180, action: 'works#mods')
          RequestLatency.record(700, action: 'works#mods', server_error: true)
        end

        run_test! do |response|
          body = response.parsed_body
          expect(body).to include('window_minutes' => 30, 'calls' => 3, 'server_errors' => 1)
          expect(body['slowest_actions'].first).to include('action' => 'works#mods', 'calls' => 2)
        end
      end

      response '503', 'Redis, which holds the figures, does not answer' do
        let(:minutes) { nil }
        before { allow(RequestLatency).to receive(:summary).and_raise(Redis::CannotConnectError) }

        run_test! do |response|
          expect(response.parsed_body).to include('error' => 'backend_unavailable', 'dependency' => 'cache')
        end
      end
    end
  end
end

RSpec.describe 'Metrics access and recording', type: :request do
  before do
    RequestLatency.clear!
    RequestLatency.resume!
  end

  after do
    RequestLatency.enabled = false
    RequestLatency.clear!
  end

  it 'refuses a standard user' do
    User.create!(email: 'standard-metrics@example.invalid', password: SecureRandom.hex(16),
                 nuid: '009999981', name: 'Standard, Sam', role: :standard)

    get '/metrics/latency', headers: { 'Authorization' => "Bearer #{DefaultAuthHeaders.assertion_for('009999981')}" }

    expect(response).to have_http_status(:forbidden)
  end

  it 'answers during a maintenance window' do
    MaintenanceMode.open!(source: 'operator')
    MaintenanceMode::Cache.reset

    get '/metrics/latency'

    expect(response).to have_http_status(:ok)
  ensure
    MaintenanceMode.delete_all
    MaintenanceMode::Cache.reset
  end

  it "counts the app's requests and leaves out the monitor's" do
    RequestLatency.enabled = true

    get '/maintenance'
    get '/health'
    get '/up'
    get '/metrics/latency'

    expect(response.parsed_body['calls']).to eq(1)
    expect(response.parsed_body['slowest_actions'].pluck('action')).to eq(['maintenance#show'])
  end

  it 'clamps the window to the retention' do
    get '/metrics/latency', params: { minutes: 10_000 }
    expect(response.parsed_body['window_minutes']).to eq(120)
  end
end
