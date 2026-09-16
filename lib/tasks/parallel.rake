# frozen_string_literal: true

require 'open3'

# One canonical command for the sharded spec run, so a person at a terminal and
# any future CI job invoke exactly the same thing.
#
# Each worker owns its own database (atlas_test<n>), its own Solr core
# (blacklight-test-<n>) and its own OCFL storage root (tmp/files<n>), because a
# run wipes all three at startup — two workers sharing any one of them would
# delete each other's fixtures mid-run. The suffix comes from TEST_ENV_NUMBER,
# which parallel_tests leaves empty for the first worker, so worker 1 uses the
# same stores an unsharded run has always used and nothing changes for it.
#
# The databases are created here. The Solr cores are not: creating one means
# writing a conf/ directory into the solr container, which only the host can do.
# See bin/parallel-solr-cores, which bin/parallel-spec calls before the run and
# which spec/support/spec_preflight.rb names if a core turns out to be missing.
#
# Split by recorded runtime rather than by file count. This suite's cost is
# concentrated in a handful of request and integration files, so an even split
# of *files* leaves one worker running long after the others have finished.
namespace :parallel do
  DEFAULT_WORKERS = 4

  # Written by the RuntimeLogger formatter in .rspec_parallel. Under tmp/, so it
  # is per-checkout and gitignored: a committed one would be a snapshot of one
  # machine's timings, going stale from the moment it landed.
  RUNTIME_LOG = 'tmp/parallel_runtime_rspec.log'

  desc "Run the whole suite across N workers (default #{DEFAULT_WORKERS})"
  # No :environment prerequisite, matching :smoke — this task only shells out,
  # and each worker boots the app itself.
  task :spec do # rubocop:disable Rails/RakeEnvironment
    workers = Integer(ENV.fetch('WORKERS', DEFAULT_WORKERS))

    Rake::Task['parallel:prepare'].invoke(workers)

    # Balance on recorded runtime once there is a recording to balance on, and
    # fall back to file size for the very first run on a fresh checkout. Size is
    # a poor proxy here — the heaviest file is not close to the largest — so the
    # first run may finish lopsided. It only happens once: .rspec_parallel has
    # every worker write its timings, so the next run splits on real numbers.
    strategy = File.exist?(RUNTIME_LOG) ? 'runtime' : 'filesize'
    puts "splitting #{workers} ways by #{strategy}"

    # verbose: false suppresses rake's echo of the command, which this task has
    # just described in friendlier terms. Each worker still prints its own seed,
    # counts and timing — that is the part a reader acts on.
    sh "bundle exec parallel_rspec -n #{workers} --group-by #{strategy}", verbose: false
  end

  desc 'Create and migrate the per-worker test databases'
  task :prepare, [:workers] do |_t, args| # rubocop:disable Rails/RakeEnvironment
    workers = Integer(args[:workers] || ENV.fetch('WORKERS', DEFAULT_WORKERS))

    # Rails' own task rather than parallel_tests' database helpers, so the
    # schema lands the same way `rake db:test:prepare` lands it for worker 1.
    #
    # Output is held rather than streamed: a successful prepare says nothing a
    # reader acts on, and four of them say it four times. It is still printed
    # when a prepare fails, which is when it means something.
    workers.times do |i|
      number = i.zero? ? '' : (i + 1).to_s
      output, status = Open3.capture2e({ 'TEST_ENV_NUMBER' => number, 'RAILS_ENV' => 'test' },
                                       'bundle exec rails db:test:prepare')
      next if status.success?

      puts output
      abort("db:test:prepare failed for worker #{i + 1}")
    end
  end
end
