# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SolrCore do
  describe '.test_url' do
    it 'defaults to the single-instance core, so a stack that sets nothing is unchanged' do
      expect(described_class.test_url).to eq('http://solr:8983/solr/blacklight-test')
    end

    it 'takes ATLAS_TEST_SOLR_URL, so parallel test instances can each own a core' do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch)
        .with('ATLAS_TEST_SOLR_URL', described_class::DEFAULT_TEST_URL)
        .and_return('http://solr:8983/solr/blacklight-test-2')

      expect(described_class.test_url).to eq('http://solr:8983/solr/blacklight-test-2')
    end
  end

  describe '.url' do
    it 'follows the test core in test' do
      expect(described_class.url).to eq(described_class.test_url)
    end

    it 'is the index core outside test' do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new('production'))

      expect(described_class.url).to eq('http://solr:8983/solr/blacklight-core')
    end
  end

  # Reset (MaintenanceController#reset) empties SolrCore.url. If the :test_solr
  # adapter wrote somewhere else, a reset would leave its documents in place and
  # delete another instance's instead.
  it 'names the core the :test_solr adapter actually writes to' do
    adapter_url = Valkyrie::MetadataAdapter.find(:test_solr).connection.uri.to_s

    expect(adapter_url.chomp('/')).to eq(described_class.url)
  end
end
