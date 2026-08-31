# frozen_string_literal: true

# The Solr core Atlas reads and writes, in one place so the writers and the
# reset that wipes them cannot name different cores — an adapter indexing into
# one core while reset empties another fails silently and expensively.
module SolrCore
  INDEX_URL = 'http://solr:8983/solr/blacklight-core'
  DEFAULT_TEST_URL = 'http://solr:8983/solr/blacklight-test'

  # The test core is env-driven so several Atlas instances can run RAILS_ENV=test
  # against one Solr, each owning a core. Sharing a core makes each instance's
  # reset delete the others' documents. The default is the single-instance value,
  # so a stack that sets nothing behaves as before.
  def self.test_url
    ENV.fetch('ATLAS_TEST_SOLR_URL', DEFAULT_TEST_URL)
  end

  def self.url
    Rails.env.test? ? test_url : INDEX_URL
  end
end
