# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ResponseCache, :response_cache do
  describe '.key' do
    it 'names the scope, the noid and the audience' do
      expect(described_class.key(scope: 'works.show', noid: 'abc123', audience: :any))
        .to eq('atlas/response/v3/works.show/abc123/any')
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

  describe '.clear!' do
    it 'drops every entry it owns and leaves the rest of the store alone' do
      described_class.write(scope: 'works.show', noid: 'aaa', status: 200, body: '1', content_type: 'application/json')
      described_class.write(scope: 'resources.permissions', noid: 'bbb', status: 200, body: '2',
                            content_type: 'application/json')
      Rails.cache.write('atlas/other/aaa', 'keep me')

      described_class.clear!

      expect(described_class.read(scope: 'works.show', noid: 'aaa')).to be_nil
      expect(described_class.read(scope: 'resources.permissions', noid: 'bbb')).to be_nil
      expect(Rails.cache.read('atlas/other/aaa')).to eq('keep me')
    end

    # RedisCacheStore raises on a Regexp, and no Redis runs in the suite, so the
    # glob branch is pinned by what it hands the store.
    it 'gives a Redis store a glob, not a Regexp' do
      redis = ActiveSupport::Cache::RedisCacheStore.new(url: 'redis://unused.invalid:6379/0')
      Rails.cache = redis
      allow(redis).to receive(:delete_matched)

      described_class.clear!

      expect(redis).to have_received(:delete_matched).with("#{ResponseCache::NAMESPACE}/*")
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
