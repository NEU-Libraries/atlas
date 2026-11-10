# frozen_string_literal: true

# Fails an example that runs past ATLAS_SPEC_WATCHDOG seconds (900 by default,
# 0 to switch it off), and writes down why before it does: a hang otherwise
# shows only as a run that never ends, and the evidence goes with the kill.
# See docs/testing.md.
module ExampleWatchdog
  LIMIT = Integer(ENV.fetch('ATLAS_SPEC_WATCHDOG', 900))
  GRACE = 10
  SLOW_QUERY = 30

  class Timeout < StandardError; end

  class << self
    def watch(example, main, backend, fired)
      sleep LIMIT
      fired << true
      path = report(example, main, backend)
      cancel(backend)
      sleep GRACE
      main.raise(Timeout, "ran past #{LIMIT}s; see #{path}") if main.alive?
    rescue StandardError => e
      warn "[watchdog] could not report: #{e.class}: #{e.message}"
    end

    private

      def report(example, main, backend)
        path = Rails.root.join('tmp', "spec-watchdog-#{ENV.fetch('TEST_ENV_NUMBER', '1').presence || '1'}-" \
                                      "#{Time.current.strftime('%Y%m%d-%H%M%S')}.log")
        File.write(path, [header(example, backend), threads(main), database].join("\n\n"))
        warn "\n[watchdog] #{example.location} ran past #{LIMIT}s; report in #{path}"
        path
      end

      def header(example, backend)
        "#{example.location} #{example.full_description}\nran past #{LIMIT}s; its Postgres backend is #{backend}"
      end

      def threads(main)
        Thread.list.map do |thread|
          label = thread == main ? 'example thread' : thread.name || thread.inspect
          "--- #{label} (#{thread.status})\n#{Array(thread.backtrace).first(60).join("\n")}"
        end.join("\n")
      end

      # A connection outside the pool: a transactional test pins one connection
      # and shares it with every thread, so a pooled one would be the example's,
      # busy with the very query that hangs.
      def own_connection
        config = ActiveRecord::Base.connection_db_config.configuration_hash
        connection = PG.connect(host: config[:host], port: config[:port], dbname: config[:database],
                                user: config[:username], password: config[:password])
        yield connection
      ensure
        connection&.close
      end

      def database
        own_connection { |session| [activity(session), slow_plans(session), dead_rows(session)].join("\n\n") }
      end

      def activity(session)
        rows = session.exec(<<~SQL.squish).to_a
          SELECT pid, state, wait_event_type, wait_event,
                 round(extract(epoch FROM now() - xact_start)) AS xact_s,
                 round(extract(epoch FROM now() - query_start)) AS query_s, query
          FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid()
        SQL
        "--- pg_stat_activity\n#{rows.map(&:inspect).join("\n")}"
      end

      # The plan comes from this session, so it uses the same statistics but
      # cannot see the example's uncommitted rows.
      def slow_plans(session)
        slow = session.exec(<<~SQL.squish).column_values(0)
          SELECT query FROM pg_stat_activity
          WHERE datname = current_database() AND state = 'active' AND pid <> pg_backend_pid()
            AND now() - query_start > interval '#{SLOW_QUERY} seconds'
        SQL
        slow.map { |query| "--- EXPLAIN\n#{query}\n#{explain(session, query)}" }.join("\n\n")
      end

      def explain(session, query)
        session.exec("EXPLAIN #{query}").column_values(0).join("\n")
      rescue StandardError => e
        "(no plan: #{e.class}: #{e.message.lines.first})"
      end

      def dead_rows(session)
        rows = session.exec(<<~SQL.squish).to_a
          SELECT relname, n_live_tup, n_dead_tup, last_autovacuum, last_autoanalyze
          FROM pg_stat_user_tables ORDER BY n_dead_tup DESC LIMIT 5
        SQL
        "--- most dead rows\n#{rows.map(&:inspect).join("\n")}"
      end

      def cancel(backend)
        return unless backend

        own_connection { |session| session.exec_params('SELECT pg_cancel_backend($1)', [Integer(backend)]) }
      end
  end
end

RSpec.configure do |config|
  config.around do |example|
    next example.run if ExampleWatchdog::LIMIT.zero? || config.dry_run?

    backend = ActiveRecord::Base.connection.raw_connection.backend_pid
    fired = []
    watcher = Thread.new(Thread.current) { |main| ExampleWatchdog.watch(example, main, backend, fired) }
    watcher.name = 'spec watchdog'
    begin
      example.run
    ensure
      watcher.kill
    end
    # App code can rescue the cancelled query and carry on; a hang still fails.
    raise ExampleWatchdog::Timeout, "ran past #{ExampleWatchdog::LIMIT}s" if fired.any? && example.exception.nil?
  end
end
