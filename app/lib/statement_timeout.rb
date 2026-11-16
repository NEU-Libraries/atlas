# frozen_string_literal: true

# Runs one block with no statement timeout, for the few statements that
# legitimately outlast the limit config/database.yml sets. See
# docs/availability.md.
module StatementTimeout
  # The connection goes back to the pool afterwards, so the limit must come
  # back too. RESET would restore the server's default of no limit rather than
  # the configured value, so this restores the value it read.
  def self.lifted(connection = ActiveRecord::Base.connection)
    previous = connection.select_value('SHOW statement_timeout')
    connection.execute('SET statement_timeout = 0')
    yield
  ensure
    connection.execute("SET statement_timeout = #{connection.quote(previous)}") if previous
  end
end
