# frozen_string_literal: true

require 'rails_helper'

RSpec.describe StaleRetry do
  let(:stale) { Valkyrie::Persistence::StaleObjectError }

  before { allow(described_class).to receive(:pause) }

  describe '.run' do
    it 'yields the attempt number and returns the block value once it succeeds' do
      seen = []
      result = described_class.run('spec') do |attempt|
        seen << attempt
        raise stale if attempt < 2

        :done
      end

      expect(result).to eq(:done)
      expect(seen).to eq([0, 1, 2])
    end

    it 're-raises after the same budget as the controller retry' do
      attempts = 0
      expect do
        described_class.run('spec') do
          attempts += 1
          raise stale
        end
      end.to raise_error(stale)
      expect(attempts).to eq(StaleObjectRetry::RETRY_MAX_ATTEMPTS)
    end
  end

  describe '.settle' do
    it 'answers nil and logs instead of raising a conflict' do
      allow(Rails.logger).to receive(:warn)

      expect(described_class.settle('derived write') { raise stale }).to be_nil
      expect(Rails.logger).to have_received(:warn).with(/derived write gave up/)
    end

    it 'lets any other error through' do
      expect { described_class.settle('spec') { raise ArgumentError } }.to raise_error(ArgumentError)
    end
  end
end
