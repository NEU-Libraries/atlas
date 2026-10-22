# frozen_string_literal: true

# Probes the services Atlas depends on, for GET /health. See
# docs/availability.md for what each check proves and what it cannot.
module SystemHealth
  OK          = 'ok'
  UNAVAILABLE = 'unavailable'
  DEGRADED    = 'degraded'
  DISABLED    = 'disabled'

  # Losing any of these stops Atlas serving part of its contract. The cache is
  # absent: a cache outage falls back to rendering.
  REQUIRED = %i[database index storage].freeze

  TTL = 5
  SOLR_OPEN_TIMEOUT = 1
  SOLR_READ_TIMEOUT = 2

  @mutex  = Mutex.new
  @cached = nil

  class << self
    # Memoized per process for TTL seconds, so a poller cannot turn the probe
    # into load. The lock also makes concurrent callers share one probe.
    def report(now: Process.clock_gettime(Process::CLOCK_MONOTONIC))
      @mutex.synchronize do
        @cached = nil if @cached && now - @cached[:at] >= TTL
        (@cached ||= { at: now, report: build }).fetch(:report)
      end
    end

    def reset!
      @mutex.synchronize { @cached = nil }
    end

    def healthy?(report)
      REQUIRED.none? { |name| report[name] == UNAVAILABLE }
    end

    private

      def build
        checks = {
          database: probe(:database) { database? },
          index:    probe(:index) { index? },
          storage:  probe(:storage) { storage? },
          cache:    cache_status
        }
        { status: overall(checks) }.merge(checks)
      end

      def overall(checks)
        return UNAVAILABLE if checks[:database] == UNAVAILABLE
        return DEGRADED if checks.value?(UNAVAILABLE)

        OK
      end

      def probe(name)
        return OK if yield

        log(name, 'check failed')
        UNAVAILABLE
      rescue StandardError => e
        log(name, "#{e.class}: #{e.message}")
        UNAVAILABLE
      end

      def log(name, detail)
        Rails.logger.error("health: #{name} unavailable: #{detail}")
      end

      def database?
        ActiveRecord::Base.connection_pool.with_connection { |conn| conn.select_value('SELECT 1').to_i == 1 }
      end

      # Its own connection rather than the persister's, which carries no
      # timeouts: a hung Solr must not hold the probe past a poller's deadline.
      def index?
        solr = RSolr.connect(url: SolrCore.url, open_timeout: SOLR_OPEN_TIMEOUT, timeout: SOLR_READ_TIMEOUT)
        solr.get('admin/ping', params: { wt: 'json' })['status'] == 'OK'
      end

      # Every root must be a writable directory. The first root also takes the
      # repository's first object, so once anything is deposited it must carry
      # the OCFL marker; an empty directory there is a volume that did not mount.
      def storage?
        roots = Valkyrie.config.storage_adapter.storage_roots.values
        return false unless roots.all? { |root| root.base_path.directory? && root.base_path.writable? }

        roots.first.provisioned? || !deposits?
      end

      # With the database down this cannot be answered, and the database row
      # already reports that; storage must not fail on its behalf.
      def deposits?
        Valkyrie::Persistence::Postgres::ORM::Resource.exists?
      rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid
        false
      end

      def cache_status
        return DISABLED unless Rails.cache.is_a?(ActiveSupport::Cache::RedisCacheStore)

        probe(:cache) { Rails.cache.redis.with { |redis| redis.ping == 'PONG' } }
      end
  end
end
