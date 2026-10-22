# frozen_string_literal: true

# Atlas's own request latency, kept per minute in Redis so every Puma worker
# and every replica adds to the same figures. See docs/read-performance.md.
module RequestLatency
  WINDOW_MINUTES = 60
  RETENTION = 2.hours
  # A Redis that will not answer must not add its connect timeout to every
  # request Atlas serves, so a failure stops writes for this long.
  BACKOFF = 30.seconds
  SLOWEST_ACTIONS = 10

  # The monitor's traffic, not the app's, by controller path. Rails's own
  # controllers (/up, and development's welcome page) are left out by namespace.
  EXCLUDED_CONTROLLERS = %w[health metrics].freeze
  # A request that matched no route still cost Atlas its time.
  UNROUTED = 'unrouted'

  Summary = Data.define(:calls, :server_errors, :mean_ms, :p50_ms, :p95_ms, :p99_ms, :slowest_actions)

  # Off in test, where a spec that wants it turns it on: otherwise every
  # request spec would write to Redis and parallel workers would count each
  # other's traffic.
  mattr_accessor :enabled, default: !Rails.env.test?

  class << self
    # Its own client at REDIS_URL, not Rails.cache: development's cache store
    # is a null store unless `rails dev:cache` is on, so nothing would record.
    def redis
      @redis ||= Redis.new(url: ENV.fetch('REDIS_URL', 'redis://redis:6379/0'), connect_timeout: 1,
                           read_timeout: 0.2, write_timeout: 0.2, reconnect_attempts: 0)
    end

    # `route` is the router's path parameters, empty or nil when no route
    # matched.
    def record_request(duration_ms, route:, status:)
      return unless enabled

      controller = route&.dig(:controller).presence&.to_s
      return if excluded?(controller)

      action = controller ? "#{controller}##{route[:action]}" : UNROUTED
      record(duration_ms, action: action, server_error: status.to_i >= 500)
    end

    def record(duration_ms, action:, server_error: false, now: Time.current)
      return if suspended?

      minute = minute_suffix(now)
      bucket = Histogram.bucket_for(duration_ms)
      redis.pipelined do |pipe|
        pipe.hincrby(key('requests', minute), bucket, 1)
        pipe.hincrbyfloat(key('requests', minute), 'sum_ms', duration_ms)
        pipe.hincrby(key('requests', minute), 'server_errors', 1) if server_error
        pipe.hincrby(key('actions', minute), "#{action}|#{bucket}", 1)
        pipe.expire(key('requests', minute), RETENTION.to_i)
        pipe.expire(key('actions', minute), RETENTION.to_i)
      end
    rescue Redis::BaseError => e
      give_up(e)
    end

    # Raises Redis::BaseError rather than reporting zeros, so the caller can
    # say the figures are unavailable.
    def summary(minutes: WINDOW_MINUTES, now: Time.current)
      totals, per_action = window_totals(minutes, now)
      counts = Histogram.counts(totals)
      calls  = counts.sum
      Summary.new(calls: calls, server_errors: totals['server_errors'].to_i,
                  mean_ms: calls.zero? ? nil : (totals['sum_ms'] / calls).round,
                  p50_ms: Histogram.percentile(counts, 0.50), p95_ms: Histogram.percentile(counts, 0.95),
                  p99_ms: Histogram.percentile(counts, 0.99),
                  slowest_actions: Histogram.slowest(per_action, SLOWEST_ACTIONS))
    end

    def suspended? = @suspended_until.present? && Time.current < @suspended_until

    def resume! = @suspended_until = nil

    # Development and specs only: deletes this namespace's keys.
    def clear!
      keys = redis.scan_each(match: "#{prefix}:*").to_a
      redis.del(*keys) if keys.any?
    end

    private

      def window_totals(minutes, now)
        suffixes = (0...minutes).map { |ago| minute_suffix(now - ago.minutes) }
        rows = redis.pipelined do |pipe|
          suffixes.each do |minute|
            pipe.hgetall(key('requests', minute))
            pipe.hgetall(key('actions', minute))
          end
        end
        requests, actions = rows.each_slice(2).to_a.transpose
        [sum_rows(requests), sum_rows(actions)]
      end

      def sum_rows(rows)
        rows.each_with_object(Hash.new(0.0)) do |row, totals|
          row.each { |field, value| totals[field] += value.to_f }
        end
      end

      def excluded?(controller)
        return false if controller.nil?

        EXCLUDED_CONTROLLERS.include?(controller) || controller.start_with?('rails/')
      end

      def minute_suffix(time) = time.utc.strftime('%Y%m%d%H%M')

      def key(series, minute) = "#{prefix}:#{series}:#{minute}"

      # The environment is in the key because development and the specs share
      # one Redis, and the parallel worker because each worker's specs clear
      # their own figures.
      def prefix = "atlas:latency:#{Rails.env}#{ENV.fetch('TEST_ENV_NUMBER', nil)}"

      def give_up(error)
        Rails.logger.warn("[latency] Redis did not answer, pausing writes: #{error.class}: #{error.message}")
        @suspended_until = Time.current + BACKOFF
        nil
      end
  end
end
