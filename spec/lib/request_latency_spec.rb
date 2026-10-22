# frozen_string_literal: true

require 'rails_helper'

RSpec.describe RequestLatency do
  let(:now) { Time.utc(2026, 10, 22, 12, 30) }

  before do
    described_class.clear!
    described_class.resume!
  end

  after do
    described_class.enabled = false
    described_class.resume!
    described_class.clear!
  end

  def summary(minutes: 60) = described_class.summary(minutes: minutes, now: now)

  it 'reports nothing, not zeros, for an empty window' do
    expect(summary).to have_attributes(calls: 0, server_errors: 0, mean_ms: nil, p95_ms: nil, slowest_actions: [])
  end

  it 'sums calls, 5xx and the mean across the minutes of the window' do
    described_class.record(20, action: 'works#show', now: now)
    described_class.record(40, action: 'works#show', now: now - 5.minutes)
    described_class.record(60, action: 'works#create', server_error: true, now: now - 59.minutes)

    expect(summary).to have_attributes(calls: 3, server_errors: 1, mean_ms: 40)
  end

  it 'leaves out minutes older than the window' do
    described_class.record(20, action: 'works#show', now: now - 10.minutes)
    expect(summary(minutes: 10).calls).to eq(0)
  end

  it 'interpolates percentiles inside the bucket that holds the rank' do
    90.times { described_class.record(30, action: 'works#show', now: now) }
    10.times { described_class.record(400, action: 'works#mods', now: now) }

    # 90 calls in (25, 50] and 10 in (250, 500]: the median sits halfway
    # through the first bucket, the p95 halfway through the second.
    expect(summary).to have_attributes(p50_ms: 39, p95_ms: 375, p99_ms: 475)
  end

  it 'reports the last edge for a rank in the open top bucket' do
    described_class.record(60_000, action: 'works#show', now: now)
    expect(summary.p99_ms).to eq(10_000)
  end

  it 'ranks actions by p95' do
    5.times { described_class.record(8, action: 'works#show', now: now) }
    described_class.record(900, action: 'works#mods', now: now)

    expect(summary.slowest_actions).to eq([{ action: 'works#mods', calls: 1, p95_ms: 975 },
                                           { action: 'works#show', calls: 5, p95_ms: 10 }])
  end

  describe 'record_event' do
    def event(controller:, action: 'show', status: 200, exception: nil)
      instance_double(ActiveSupport::Notifications::Event, duration: 12.5,
                                                           payload:  { controller: controller, action: action,
                                                                      status: status, exception: exception })
    end

    before { described_class.enabled = true }

    it 'names the action by controller path, never by URL' do
      described_class.record_event(event(controller: 'Users::TokensController', action: 'nuid'))
      expect(described_class.summary.slowest_actions.first[:action]).to eq('users/tokens#nuid')
    end

    it 'counts an unhandled exception as a 5xx' do
      described_class.record_event(event(controller: 'WorksController', status: nil,
                                         exception: %w[RuntimeError boom]))
      expect(described_class.summary.server_errors).to eq(1)
    end

    it "skips the monitor's own routes" do
      %w[HealthController MetricsController Rails::HealthController Rails::WelcomeController].each do |controller|
        described_class.record_event(event(controller: controller))
      end
      expect(described_class.summary.calls).to eq(0)
    end

    it 'records nothing while disabled' do
      described_class.enabled = false
      described_class.record_event(event(controller: 'WorksController'))
      expect(described_class.summary.calls).to eq(0)
    end
  end

  describe 'a Redis that does not answer' do
    it 'pauses writes instead of failing the request' do
      allow(described_class.redis).to receive(:pipelined).and_raise(Redis::CannotConnectError)

      expect { described_class.record(10, action: 'works#show') }.not_to raise_error
      expect(described_class).to be_suspended

      described_class.record(10, action: 'works#show')
      expect(described_class.redis).to have_received(:pipelined).once
    end
  end
end
