# frozen_string_literal: true

# Keeps the planner from believing a test table is empty while a spec fills it.
# A vacuum that runs mid-suite records zero live rows, cannot truncate past the
# lock an open example holds, and leaves a nonzero page count, and from that the
# planner reads every later row count as zero. See docs/testing.md.
module PlannerStats
  class << self
    def reset!(connection = ActiveRecord::Base.connection)
      tables(connection).each do |table|
        quoted = connection.quote_table_name(table)
        connection.execute("ALTER TABLE #{quoted} SET (autovacuum_enabled = false, toast.autovacuum_enabled = false)")
        connection.execute("VACUUM #{quoted}")
      end
    end

    def tables(connection)
      connection.select_values("SELECT relname FROM pg_stat_user_tables WHERE schemaname = 'public' ORDER BY relname")
    end
  end
end

RSpec.configure do |config|
  config.before(:suite) { PlannerStats.reset! }
end
