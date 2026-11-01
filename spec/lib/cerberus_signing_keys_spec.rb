# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CerberusSigningKeys do
  let(:key_a) { OpenSSL::PKey::EC.generate('prime256v1') }
  let(:key_b) { OpenSSL::PKey::EC.generate('prime256v1') }

  def configure(keyset)
    allow(Rails.application.credentials).to receive(:cerberus_signing_keys).and_return(keyset)
  end

  it 'parses the keyset into kid => public key' do
    configure({ a: key_a.public_to_pem })
    expect(described_class.current.keys).to eq(['a'])
    expect(described_class.current['a'].public_to_pem).to eq(key_a.public_to_pem)
  end

  it 'parses once while the configured value is unchanged' do
    configure({ 'a' => key_a.public_to_pem })
    allow(OpenSSL::PKey).to receive(:read).and_call_original

    3.times { described_class.current }
    expect(OpenSSL::PKey).to have_received(:read).once
  end

  it 'reparses a rotated keyset, dropping the retired kid' do
    configure({ 'a' => key_a.public_to_pem })
    described_class.current
    configure({ 'b' => key_b.public_to_pem })

    expect(described_class.current.keys).to eq(['b'])
  end

  it 'is empty when no keyset is configured' do
    configure(nil)
    expect(described_class.current).to eq({})
  end

  it 'is empty when a PEM does not parse' do
    configure({ 'a' => 'not a pem' })
    expect(described_class.current).to eq({})
  end
end
