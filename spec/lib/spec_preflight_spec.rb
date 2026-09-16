# frozen_string_literal: true

require 'rails_helper'

# The guard that stops a run wiping the development database or the development
# index. It cannot be exercised against a real wrong target without doing the
# damage it exists to prevent, so it is asserted here instead.
RSpec.describe SpecPreflight do
  describe '.assert_test_solr_core!' do
    it 'accepts the unsharded core' do
      allow(SolrCore).to receive(:url).and_return('http://solr:8983/solr/blacklight-test')

      expect { described_class.assert_test_solr_core! }.not_to raise_error
    end

    it 'accepts a worker core' do
      allow(SolrCore).to receive(:url).and_return('http://solr:8983/solr/blacklight-test-3')

      expect { described_class.assert_test_solr_core! }.not_to raise_error
    end

    it 'refuses the index core, which a run would otherwise empty' do
      allow(SolrCore).to receive(:url).and_return('http://solr:8983/solr/blacklight-core')

      expect { described_class.assert_test_solr_core! }
        .to raise_error(described_class::UnsafeTarget, /blacklight-core/)
    end
  end

  describe '.assert_test_database!' do
    it 'accepts the unsharded database' do
      stub_database('atlas_test')

      expect { described_class.assert_test_database! }.not_to raise_error
    end

    it 'accepts a worker database' do
      stub_database('atlas_test3')

      expect { described_class.assert_test_database! }.not_to raise_error
    end

    it 'refuses the development database, which a run would otherwise truncate' do
      stub_database('atlas_development')

      expect { described_class.assert_test_database! }
        .to raise_error(described_class::UnsafeTarget, /atlas_development/)
    end
  end

  describe '.assert_test_env!' do
    it 'refuses any environment but test' do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new('development'))

      expect { described_class.assert_test_env! }
        .to raise_error(described_class::UnsafeTarget, /RAILS_ENV is development/)
    end
  end

  def stub_database(name)
    config = ActiveRecord::Base.connection_db_config
    allow(config).to receive(:database).and_return(name)
    allow(ActiveRecord::Base).to receive(:connection_db_config).and_return(config)
  end
end
