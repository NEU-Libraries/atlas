# frozen_string_literal: true

require 'net/http'
require 'uri'

# Refuses to start a run that would wipe something other than the test stores.
#
# The suite opens by emptying the OCFL storage root and calling
# Atlas.persister.wipe!, which truncates Postgres and deletes every document in
# the Solr core the :test_solr adapter names. Both targets are env-derived so
# that parallel workers can each own one — and an env that resolved to the
# development core or the development database would be wiped just as readily,
# then leave a hundred unrelated red examples burying the one line that
# mattered.
#
# The checks run before the wipe, cost nothing, and name their own fix.
module SpecPreflight
  # Every test core is a suffixed form of this, one per parallel worker. The
  # index core (blacklight-core) is what must never match.
  TEST_CORE_PREFIX = 'blacklight-test'

  # Every test database is a suffixed form of this. atlas_development and
  # atlas_production are what must never match.
  TEST_DATABASE_PREFIX = 'atlas_test'

  class UnsafeTarget < StandardError; end

  def self.assert_safe_to_wipe!
    assert_test_env!
    assert_test_solr_core!
    assert_test_database!
    assert_solr_core_loaded!
  end

  def self.assert_test_env!
    return if Rails.env.test?

    raise UnsafeTarget, <<~MSG
      Refusing to run: this suite wipes the stores it points at, and RAILS_ENV is #{Rails.env}.

      Run it with RAILS_ENV=test. Outside test the adapters resolve to the
      development index and the development database.
    MSG
  end

  def self.assert_test_solr_core!
    core = SolrCore.url.split('/').last
    return if core.start_with?(TEST_CORE_PREFIX)

    raise UnsafeTarget, <<~MSG
      Refusing to run: the suite deletes every document in the Solr core it points at, and that core is "#{core}".

        SolrCore.url           #{SolrCore.url}
        ATLAS_TEST_SOLR_URL    #{ENV.fetch('ATLAS_TEST_SOLR_URL', nil).inspect}
        TEST_ENV_NUMBER        #{ENV.fetch('TEST_ENV_NUMBER', nil).inspect}
        expected               a core named "#{TEST_CORE_PREFIX}" or "#{TEST_CORE_PREFIX}-<worker>"

      Running now would empty the development index, leaving search results that
      all 404 until a reindex.
    MSG
  end

  # A worker's core is provisioned on the host, not by the suite, so it is
  # legitimately absent the first time a machine runs sharded. Without this the
  # run dies on the first index write with an RSolr 404 several frames deep,
  # which reads as a Solr outage rather than as a core nobody created yet.
  def self.assert_solr_core_loaded!
    uri = URI.parse("#{SolrCore.url}/admin/ping")
    response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 5) do |http|
      http.request(Net::HTTP::Get.new(uri))
    end
    return if response.is_a?(Net::HTTPSuccess)

    raise UnsafeTarget, core_missing_message(response.code)
  rescue SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout => e
    raise UnsafeTarget, core_missing_message(e.class.name)
  end

  def self.core_missing_message(reason)
    <<~MSG
      Refusing to run: #{SolrCore.url} did not answer its ping (#{reason}).

      Each parallel worker indexes into its own core, and only worker 1's
      "#{TEST_CORE_PREFIX}" ships with the Solr image. The cores do not survive a
      Solr recreate, so provision them again after any stack rebuild:

        bin/parallel-solr-cores 4

      bin/parallel-spec runs that for you before it starts the workers.
    MSG
  end

  def self.assert_test_database!
    name = ActiveRecord::Base.connection_db_config.database
    return if name.to_s.start_with?(TEST_DATABASE_PREFIX)

    raise UnsafeTarget, <<~MSG
      Refusing to run: the suite truncates the database it connects to, and that database is "#{name}".

        TEST_ENV_NUMBER   #{ENV.fetch('TEST_ENV_NUMBER', nil).inspect}
        DATABASE_URL      #{ENV.fetch('DATABASE_URL', nil).inspect}
        expected          a database named "#{TEST_DATABASE_PREFIX}" or "#{TEST_DATABASE_PREFIX}<worker>"

      A DATABASE_URL in the environment overrides config/database.yml entirely,
      including the per-worker suffix, so check that first.
    MSG
  end
end
