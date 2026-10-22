# frozen_string_literal: true

require 'rails_helper'

# The health report and the outage 503 through the live server. Both contracts
# span two repos — Atlas's status and envelope, atlas_rb's reading of them — so
# only the round trip proves them.
RSpec.describe 'Health and outage signals via atlas_rb', :atlas_rb_server do
  before do
    FileUtils.mkdir_p(TestStorage.root)
    SystemHealth.reset!
  end

  after { SystemHealth.reset! }

  describe 'AtlasRb::Health.read' do
    it 'returns the report when every dependency answers' do
      report = AtlasRb::Health.read

      expect(report['status']).to eq('ok')
      expect(report['database']).to eq('ok')
      expect(report['index']).to eq('ok')
      expect(report['storage']).to eq('ok')
    end

    it 'needs no credential at all' do
      AtlasRb.config.assertion_signing_key = nil

      expect(AtlasRb::Health.read['status']).to eq('ok')
    end

    # A 503 here is an answer, so it comes back as data rather than raising.
    it 'returns the report, not an error, when Atlas answers 503' do
      allow(SolrCore).to receive(:url).and_return('http://localhost:1/solr/absent')

      report = AtlasRb::Health.read

      expect(report['status']).to eq('degraded')
      expect(report['index']).to eq('unavailable')
    end

    it 'raises only when nothing answers' do
      url = ENV.fetch('ATLAS_URL')
      ENV['ATLAS_URL'] = 'http://localhost:1'

      expect { AtlasRb::Health.read }.to raise_error(Faraday::ConnectionFailed)
    ensure
      ENV['ATLAS_URL'] = url
    end
  end

  describe 'a dependency outage on an ordinary call' do
    let!(:community) { CommunityCreator.call }

    # Not a ResourceError: a host treats that as a refusal of the request.
    it 'raises BackendUnavailableError naming the dependency' do
      allow(User).to receive(:resolve_account).and_raise(ActiveRecord::ConnectionNotEstablished)

      expect { AtlasRb::Community.find(community.noid, nuid: ATLAS_RB_SERVER_ADMIN_NUID) }
        .to raise_error(AtlasRb::BackendUnavailableError) do |error|
          expect(error.dependency).to eq('database')
          expect(error.retry_after).to eq(BackendUnavailable::RETRY_AFTER)
          expect(error).not_to be_a(AtlasRb::ResourceError)
        end
    end
  end
end
