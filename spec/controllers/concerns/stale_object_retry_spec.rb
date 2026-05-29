# frozen_string_literal: true

require 'rails_helper'

describe StaleObjectRetry do
  # Minimal host standing in for a controller: mixes in the concern and
  # supplies the controller_name / action_name / params the log lines
  # interpolate. with_stale_object_retry is private, so specs reach it
  # via send.
  let(:host_class) do
    Class.new do
      include StaleObjectRetry

      def controller_name = 'works'
      def action_name      = 'update_thumbnails'
      def params           = { id: 'abc123' }
    end
  end

  subject(:host) { host_class.new }

  let(:sleeps) { [] }

  before { allow(host).to receive(:sleep) { |seconds| sleeps << seconds } }

  describe 'backoff shape' do
    it 'sleeps with exponential full jitter, never exceeding the per-attempt cap' do
      expect do
        host.send(:with_stale_object_retry) { raise Valkyrie::Persistence::StaleObjectError }
      end.to raise_error(Valkyrie::Persistence::StaleObjectError)

      # Three executions of the block (initial + two retries); the third
      # failure re-raises before sleeping, so there are exactly two sleeps.
      expect(sleeps.length).to eq(StaleObjectRetry::RETRY_MAX_ATTEMPTS - 1)

      sleeps.each_with_index do |seconds, index|
        attempt = index + 1
        cap     = StaleObjectRetry::RETRY_BASE_SECONDS * (2**attempt)
        expect(seconds).to be >= 0
        expect(seconds).to be <= cap
      end
    end

    it 'uses a monotonically increasing cap per attempt' do
      caps = (1...StaleObjectRetry::RETRY_MAX_ATTEMPTS).map do |attempt|
        StaleObjectRetry::RETRY_BASE_SECONDS * (2**attempt)
      end
      expect(caps).to eq(caps.sort)
      expect(caps.uniq).to eq(caps)
    end
  end

  describe 'exhaustion' do
    it 're-raises the original error after RETRY_MAX_ATTEMPTS' do
      attempts = 0
      expect do
        host.send(:with_stale_object_retry) do
          attempts += 1
          raise Valkyrie::Persistence::StaleObjectError
        end
      end.to raise_error(Valkyrie::Persistence::StaleObjectError)

      expect(attempts).to eq(StaleObjectRetry::RETRY_MAX_ATTEMPTS)
    end
  end

  describe 'recovery' do
    it 'returns the block result when a later attempt succeeds' do
      attempts = 0
      result = host.send(:with_stale_object_retry) do
        attempts += 1
        raise Valkyrie::Persistence::StaleObjectError if attempts < 2

        :converged
      end

      expect(result).to eq(:converged)
      expect(attempts).to eq(2)
      expect(sleeps.length).to eq(1)
    end

    it 'does not retry on a non-stale error' do
      attempts = 0
      expect do
        host.send(:with_stale_object_retry) do
          attempts += 1
          raise ArgumentError, 'unrelated'
        end
      end.to raise_error(ArgumentError)

      expect(attempts).to eq(1)
      expect(sleeps).to be_empty
    end
  end
end
