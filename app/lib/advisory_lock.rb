# frozen_string_literal: true

# A Postgres session advisory lock around one block, keyed by a scope and an
# id. A session lock and not a transaction, because the block also writes Solr
# and OCFL, which no rollback could undo. See docs/write-safety.md.
module AdvisoryLock
  def self.hold(scope, id)
    connection = ActiveRecord::Base.connection
    key = ActiveRecord::Base.sanitize_sql_array(['hashtext(?), hashtext(?)', scope, id.to_s])
    connection.execute("SELECT pg_advisory_lock(#{key})")
    begin
      yield
    ensure
      connection.execute("SELECT pg_advisory_unlock(#{key})")
    end
  end
end
