# frozen_string_literal: true

# The rules for a v1 pid a migrated resource carries: its shape, and the claim
# that keeps it unique across every resource type. See docs/legacy-pids.md.
module LegacyPid
  # The pattern Cerberus's v1 routes accept, so every pid recorded here is one
  # an inbound v1 URL can name.
  SHAPE = %r{\Aneu:[^/.?]+\z}

  def self.valid?(pid)
    SHAPE.match?(pid.to_s)
  end

  # The holder, live or tombstoned, or nil. A tombstoned resource keeps its pid,
  # so an old v1 URL still lands on its tombstone page.
  def self.holder(pid)
    Atlas.query.custom_queries.find_resource_by_legacy_pid(legacy_pid: pid)
  end

  # Runs the create when the pid is free. A nil pid claims nothing.
  def self.claim(pid)
    return yield if pid.nil?
    unless valid?(pid)
      raise Exceptions::LegacyPidError.new(:invalid_legacy_pid, "#{pid.inspect} is not a v1 pid, e.g. neu:1234")
    end

    with_lock(pid) do
      refuse_taken!(pid)
      yield
    end
  end

  def self.refuse_taken!(pid)
    taken = holder(pid)
    return if taken.nil?

    raise Exceptions::LegacyPidError.new(:legacy_pid_taken, "#{taken.class.name} #{taken.noid} already holds #{pid}",
                                         holder_id: taken.noid)
  end
  private_class_method :refuse_taken!

  # Serializes creates that bring the SAME pid, so two concurrent ones cannot
  # both pass the check. A session lock and not a transaction: the create also
  # writes Solr and OCFL, which no Postgres rollback could undo.
  def self.with_lock(pid)
    connection = ActiveRecord::Base.connection
    key = ActiveRecord::Base.sanitize_sql_array(['hashtext(?), hashtext(?)', 'legacy_pid', pid])
    connection.execute("SELECT pg_advisory_lock(#{key})")
    begin
      yield
    ensure
      connection.execute("SELECT pg_advisory_unlock(#{key})")
    end
  end
  private_class_method :with_lock
end
