# frozen_string_literal: true

require 'rails_helper'

RSpec.describe OAI::ResumptionToken do
  let(:payload) do
    { 'metadataPrefix' => 'mods', 'set' => 'abc123', 'from' => '2026-01-01T00:00:00Z',
      'cursorMark' => 'AoEoTk9JRA==', 'cursor' => 50, 'completeListSize' => 900 }
  end

  it 'round-trips a payload' do
    expect(described_class.decode(described_class.encode(payload))).to eq(payload)
  end

  # A `+` in a query string decodes to a space, so standard base64 would
  # corrupt roughly half the tokens a harvester sends back.
  it 'is url-safe and unpadded' do
    expect(described_class.encode(payload)).to match(/\A[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\z/)
  end

  it 'drops keys outside the known fields' do
    token = described_class.encode(payload.merge('fq' => '*:*'))

    expect(described_class.decode(token)).not_to have_key('fq')
  end

  describe 'rejection' do
    # The payload carries a cursorMark and a set noid that go straight into a
    # Solr query, so an unsigned or altered token must never be honoured.
    it 'refuses a tampered payload' do
      _body, signature = described_class.encode(payload).split('.')
      forged = Base64.urlsafe_encode64('{"set":"evil"}', padding: false)

      expect { described_class.decode("#{forged}.#{signature}") }
        .to raise_error(described_class::InvalidToken)
    end

    it 'refuses a token signed with another key' do
      body = Base64.urlsafe_encode64(JSON.generate(payload), padding: false)
      other = Base64.urlsafe_encode64(OpenSSL::HMAC.digest('SHA256', 'wrong', body), padding: false)

      expect { described_class.decode("#{body}.#{other}") }
        .to raise_error(described_class::InvalidToken)
    end

    it 'refuses a malformed token' do
      ['', 'nodot', 'a.', '.b', 'not base64!.sig'].each do |value|
        expect { described_class.decode(value) }.to raise_error(described_class::InvalidToken)
      end
    end

    it 'refuses a body that is not a JSON object' do
      body = Base64.urlsafe_encode64('[1,2,3]', padding: false)
      signed = described_class.encode({})
      # Re-sign the array body by hand: only the payload is being attacked.
      expect { described_class.decode("#{body}.#{signed.split('.').last}") }
        .to raise_error(described_class::InvalidToken)
    end
  end
end
