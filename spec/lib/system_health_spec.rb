# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SystemHealth do
  let(:root_dir) { Pathname.new(Dir.mktmpdir('health-root-')) }
  let(:root) { Valkyrie::Storage::OCFL::StorageRoot.new(base_path: root_dir) }
  let(:adapter) { instance_double(Valkyrie::Storage::OCFL, storage_roots: { 'r001' => root }) }

  before do
    described_class.reset!
    allow(Valkyrie.config).to receive(:storage_adapter).and_return(adapter)
  end

  after do
    described_class.reset!
    FileUtils.chmod(0o755, root_dir) if root_dir.exist?
    FileUtils.rm_rf(root_dir)
  end

  let(:report) { described_class.report }

  describe 'storage' do
    it 'is ok for an empty root before anything is deposited' do
      expect(report[:storage]).to eq('ok')
    end

    it 'is ok for a bootstrapped root once deposits exist' do
      root.bootstrap!
      allow(Valkyrie::Persistence::Postgres::ORM::Resource).to receive(:exists?).and_return(true)
      expect(report[:storage]).to eq('ok')
    end

    # The volume did not mount, so the path is the image's empty directory.
    it 'is unavailable when the first root lacks the OCFL marker but deposits exist' do
      allow(Valkyrie::Persistence::Postgres::ORM::Resource).to receive(:exists?).and_return(true)
      expect(report[:storage]).to eq('unavailable')
    end

    it 'is unavailable when a root is missing' do
      FileUtils.rm_rf(root_dir)
      expect(report[:storage]).to eq('unavailable')
    end

    it 'is unavailable when a root is not writable' do
      allow(root.base_path).to receive(:writable?).and_return(false)
      expect(report[:storage]).to eq('unavailable')
    end

    it 'does not fail on behalf of a database it cannot ask' do
      allow(Valkyrie::Persistence::Postgres::ORM::Resource).to receive(:exists?)
        .and_raise(ActiveRecord::ConnectionNotEstablished)
      expect(report[:storage]).to eq('ok')
    end
  end

  describe 'cache' do
    it 'is disabled when no Redis store is configured' do
      expect(report[:cache]).to eq('disabled')
    end

    context 'with a Redis store' do
      let(:redis) { double('redis') }
      let(:store) { ActiveSupport::Cache::RedisCacheStore.new(redis: -> { redis }) }

      before { allow(Rails).to receive(:cache).and_return(store) }

      it 'is ok when Redis answers' do
        allow(redis).to receive(:ping).and_return('PONG')
        expect(report[:cache]).to eq('ok')
      end

      it 'is unavailable, and the status degraded but healthy, when Redis does not' do
        allow(redis).to receive(:ping).and_raise(Redis::CannotConnectError)
        expect(report).to include(status: 'degraded', cache: 'unavailable')
        expect(described_class.healthy?(report)).to be(true)
      end
    end
  end

  describe 'the status' do
    it 'is ok when everything answers' do
      expect(report).to include(status: 'ok', database: 'ok', index: 'ok')
      expect(described_class.healthy?(report)).to be(true)
    end

    it 'is unavailable when the database is down' do
      allow(ActiveRecord::Base.connection_pool).to receive(:with_connection)
        .and_raise(ActiveRecord::ConnectionNotEstablished)
      expect(report).to include(status: 'unavailable', database: 'unavailable')
      expect(described_class.healthy?(report)).to be(false)
    end

    it 'logs the detail it keeps out of the body' do
      allow(SolrCore).to receive(:url).and_return('http://localhost:1/solr/absent')
      allow(Rails.logger).to receive(:error)

      expect(report[:index]).to eq('unavailable')
      expect(Rails.logger).to have_received(:error).with(/health: index unavailable: RSolr::Error::ConnectionRefused/)
    end
  end

  describe 'memoization' do
    it 'reuses a report inside the TTL and probes again after it' do
      allow(SolrCore).to receive(:url).and_call_original

      described_class.report(now: 100)
      described_class.report(now: 104)
      expect(SolrCore).to have_received(:url).once

      described_class.report(now: 105)
      expect(SolrCore).to have_received(:url).twice
    end
  end
end
