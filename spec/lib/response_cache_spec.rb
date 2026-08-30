# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ResponseCache, :response_cache do
  describe '.key' do
    it 'names the scope, the noid and the audience' do
      expect(described_class.key(scope: 'works.show', noid: 'abc123', audience: :any))
        .to eq('atlas/response/v1/works.show/abc123/any')
    end

    # The guard that keeps eviction honest: eviction walks SCOPES, so an
    # endpoint cached under a scope this class does not list would never be
    # dropped. Raising means that mistake surfaces on the endpoint's first read
    # rather than as a stale body weeks later.
    it 'refuses a scope it does not know' do
      expect { described_class.key(scope: 'works.secret', noid: 'abc123', audience: :any) }
        .to raise_error(ArgumentError, /unknown response cache scope/)
    end

    it 'refuses an audience it does not know' do
      expect { described_class.key(scope: 'works.show', noid: 'abc123', audience: :admins) }
        .to raise_error(ArgumentError, /unknown response cache audience/)
    end
  end

  describe '.evict' do
    it 'drops every scope and audience for the noid, and nothing else' do
      described_class.write(scope: 'works.show',   noid: 'aaa', status: 200, body: '1', content_type: 'application/json')
      described_class.write(scope: 'works.assets', noid: 'aaa', audience: :guest,
                            status: 200, body: '2', content_type: 'application/json')
      described_class.write(scope: 'works.show',   noid: 'bbb', status: 200, body: '3', content_type: 'application/json')

      described_class.evict('aaa')

      expect(described_class.read(scope: 'works.show', noid: 'aaa')).to be_nil
      expect(described_class.read(scope: 'works.assets', noid: 'aaa', audience: :guest)).to be_nil
      expect(described_class.read(scope: 'works.show', noid: 'bbb')&.body).to eq('3')
    end
  end

  describe '.enabled?' do
    it 'is false on a null store, so the rest of the suite renders as before' do
      Rails.cache = ActiveSupport::Cache::NullStore.new
      expect(described_class).not_to be_enabled
    end

    it 'is false when switched off by env' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('ATLAS_RESPONSE_CACHE').and_return('off')
      expect(described_class).not_to be_enabled
    end

    it 'stores nothing while disabled' do
      Rails.cache = ActiveSupport::Cache::NullStore.new
      described_class.write(scope: 'works.show', noid: 'aaa', status: 200, body: '1',
                            content_type: 'application/json')
      expect(described_class.read(scope: 'works.show', noid: 'aaa')).to be_nil
    end
  end

  describe '.ttl' do
    it 'defaults to an hour and honours the env override' do
      expect(described_class.ttl).to eq(1.hour)

      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('ATLAS_RESPONSE_CACHE_TTL').and_return('120')
      expect(described_class.ttl).to eq(120.seconds)
    end
  end
end
