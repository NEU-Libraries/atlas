# frozen_string_literal: true

require 'rails_helper'

# Atlas's latency figures through the live server: the recording subscriber,
# the admin gate and the binding's reading of each answer.
RSpec.describe 'Request latency via atlas_rb', :atlas_rb_server do
  before do
    RequestLatency.clear!
    RequestLatency.resume!
    RequestLatency.enabled = true
  end

  after do
    RequestLatency.enabled = false
    RequestLatency.clear!
  end

  it 'reports the requests Atlas served, timed by Atlas' do
    community = CommunityCreator.call
    3.times { AtlasRb::Community.find(community.noid, nuid: ATLAS_RB_SERVER_ADMIN_NUID) }
    AtlasRb::Health.read

    latency = AtlasRb::Metrics.latency(minutes: 5, nuid: ATLAS_RB_SERVER_ADMIN_NUID)

    expect(latency['window_minutes']).to eq(5)
    expect(latency['calls']).to eq(3)
    expect(latency['p95_ms']).to be_a(Integer)
    expect(latency['slowest_actions'].pluck('action')).to eq(['communities#show'])
  end

  it 'refuses a caller who is not an admin with a ResourceError' do
    User.create!(email: 'standard-latency@example.invalid', password: SecureRandom.hex(16),
                 nuid: '009999982', name: 'Standard, Sky', role: :standard)

    expect { AtlasRb::Metrics.latency(nuid: '009999982') }
      .to raise_error(AtlasRb::ResourceError) { |error| expect(error.status).to eq(403) }
  end

  it 'raises BackendUnavailableError when Redis does not answer' do
    allow(RequestLatency).to receive(:summary).and_raise(Redis::CannotConnectError)

    expect { AtlasRb::Metrics.latency(nuid: ATLAS_RB_SERVER_ADMIN_NUID) }
      .to raise_error(AtlasRb::BackendUnavailableError) { |error| expect(error.dependency).to eq('cache') }
  end
end
