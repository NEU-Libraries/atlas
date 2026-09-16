# frozen_string_literal: true

# Serializes rspec runs against the stores a run destroys on startup. The
# suite's `before(:suite)` empties the OCFL storage root, wipes Postgres and the
# test Solr core through Atlas.persister, and deletes every AuditEvent.
#
# Two overlapping runs therefore delete each other's fixtures: the second run's
# wipe lands in the middle of the first one's examples. The damage surfaces in
# whatever file happened to be executing, as a cluster of failures that pass
# when that file is re-run alone — which reads like a bug in that file rather
# than a collision, and costs a long time to attribute.
#
# The develop checkout and every worktree run inside the same web container and
# share the database and the Solr core, so a worktree run and a develop run
# collide even though their storage roots differ. That is why the lock lives in
# the container's /tmp rather than in a checkout.
#
# flock is used rather than a pidfile because the kernel releases it when the
# process dies, so a killed run leaves nothing stale to clear by hand.
module ExclusiveRunLock
  # One lock per worker, because each parallel worker owns its own database,
  # Solr core and storage root. A single shared path would make the workers
  # refuse each other, which is the opposite of the point — while still blocking
  # two concurrent suites, since worker N of one run and worker N of the other
  # contend for the same file.
  PATH = ENV.fetch('ATLAS_RSPEC_LOCK_PATH') do
    "/tmp/atlas-rspec-run#{ENV.fetch('TEST_ENV_NUMBER', nil)}.lock"
  end

  class << self
    # Take the lock for the lifetime of the process, or abort. Matches
    # rails_helper's existing `abort` on a pending migration: a precondition the
    # run cannot proceed without, reported as a plain message rather than a
    # backtrace through RSpec's hook machinery.
    def acquire!
      # Style/FileOpen wants the block form, but the descriptor staying open IS
      # the lock: flock is released the moment the file object closes, so a block
      # would drop the lock before the first example ran.
      handle = File.open(PATH, File::RDWR | File::CREAT, 0o644) # rubocop:disable Style/FileOpen
      abort(conflict_message) unless handle.flock(File::LOCK_EX | File::LOCK_NB)

      # Retained on the module for the same reason: a local would be eligible for
      # garbage collection mid-run, silently dropping the lock partway through.
      @handle = handle
    end

    private

      def conflict_message
        <<~MSG
          Another rspec run already holds #{PATH}.

          A run wipes the test database, the test Solr core and the OCFL storage
          root at startup, so two overlapping runs delete each other's fixtures
          and fail in unrelated-looking places.

          Wait for the other run to finish. If this run targets its own database
          and core, point ATLAS_RSPEC_LOCK_PATH at its own lock file.
        MSG
      end
  end
end
