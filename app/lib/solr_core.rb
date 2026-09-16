# frozen_string_literal: true

# The Solr core Atlas reads and writes, in one place so the writers and the
# reset that wipes them cannot name different cores — an adapter indexing into
# one core while reset empties another fails silently and expensively.
module SolrCore
  INDEX_URL = 'http://solr:8983/solr/blacklight-core'
  DEFAULT_TEST_URL = 'http://solr:8983/solr/blacklight-test'

  # The test core is env-driven so several Atlas instances can run RAILS_ENV=test
  # against one Solr, each owning a core. Sharing a core makes each instance's
  # reset delete the others' documents. An explicit ATLAS_TEST_SOLR_URL wins,
  # which is how a separate container names its core; otherwise the core follows
  # the parallel worker running in this process.
  def self.test_url
    ENV.fetch('ATLAS_TEST_SOLR_URL') { "#{DEFAULT_TEST_URL}#{worker_suffix}" }
  end

  def self.url
    Rails.env.test? ? test_url : INDEX_URL
  end

  # parallel_tests leaves TEST_ENV_NUMBER empty for the first worker and numbers
  # the rest from 2, so an unsharded run keeps the plain core it has always used
  # and only the extra workers need a core provisioned. See bin/parallel-solr-cores.
  def self.worker_suffix
    worker = ENV['TEST_ENV_NUMBER'].to_s
    worker.empty? ? '' : "-#{worker}"
  end
end
