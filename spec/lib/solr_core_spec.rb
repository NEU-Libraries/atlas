# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SolrCore do
  describe '.test_url' do
    it 'defaults to the single-instance core, so a stack that sets nothing is unchanged' do
      with_env('ATLAS_TEST_SOLR_URL' => nil, 'TEST_ENV_NUMBER' => nil) do
        expect(described_class.test_url).to eq('http://solr:8983/solr/blacklight-test')
      end
    end

    it 'takes ATLAS_TEST_SOLR_URL, so a separate test instance can own a core' do
      with_env('ATLAS_TEST_SOLR_URL' => 'http://solr:8983/solr/blacklight-test-9') do
        expect(described_class.test_url).to eq('http://solr:8983/solr/blacklight-test-9')
      end
    end

    it 'follows the parallel worker when ATLAS_TEST_SOLR_URL is unset' do
      with_env('TEST_ENV_NUMBER' => '2') do
        expect(described_class.test_url).to eq('http://solr:8983/solr/blacklight-test-2')
      end
    end

    # An explicit URL is how a separate container names its core, and it carries
    # no TEST_ENV_NUMBER of its own — so it has to win over the derived suffix
    # rather than be appended to.
    it 'prefers ATLAS_TEST_SOLR_URL over the worker suffix' do
      with_env('ATLAS_TEST_SOLR_URL' => 'http://solr:8983/solr/blacklight-test-9',
               'TEST_ENV_NUMBER'     => '2') do
        expect(described_class.test_url).to eq('http://solr:8983/solr/blacklight-test-9')
      end
    end
  end

  describe '.worker_suffix' do
    it 'is empty for the first worker, which parallel_tests leaves unnumbered' do
      with_env('TEST_ENV_NUMBER' => nil) { expect(described_class.worker_suffix).to eq('') }
    end

    it 'is the dashed worker number for the rest' do
      with_env('TEST_ENV_NUMBER' => '3') { expect(described_class.worker_suffix).to eq('-3') }
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
