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

  # parallel_tests balances on the log, and ABORTS before a single worker starts
  # when more than half the spec files are missing from it -- its
  # `allowed_missing` defaults to 50%, and the message
  # ("does not contain sufficient data to sort N test files") names neither the
  # cause nor the fix. A killed run leaves exactly that shape: timings for the
  # workers that finished and nothing for the rest, so the NEXT run is the one
  # that dies. Measuring coverage here turns a dead run into a merely slower
  # one, and keeps the log when it is good rather than deleting it on every run
  # and losing the balancing it exists for.
  RUNTIME_LOG_THRESHOLD = 0.5

  def self.runtime_log_coverage
    return 0.0 unless File.exist?(RUNTIME_LOG)

    specs = Dir['spec/**/*_spec.rb']
    return 0.0 if specs.empty?

    # Each line is "<path>:<seconds>", and a path never contains a colon, so
    # partitioning from the right splits the two without a regex.
    recorded = File.readlines(RUNTIME_LOG, chomp: true)
                   .map { |line| line.rpartition(':').first }
                   .reject(&:empty?)
                   .to_set
    specs.count { |spec| recorded.include?(spec) }.fdiv(specs.size)
  end

  desc "Run the whole suite across N workers (default #{DEFAULT_WORKERS})"
  # No :environment prerequisite, matching :smoke — this task only shells out,
  # and each worker boots the app itself.
  task :spec do # rubocop:disable Rails/RakeEnvironment
    workers = Integer(ENV.fetch('WORKERS', DEFAULT_WORKERS))

    Rake::Task['parallel:prepare'].invoke(workers)

    # Balance on recorded runtime once there is a usable recording to balance
    # on, and fall back to file size otherwise — a fresh checkout, or a log too
    # thin to sort by. Size is a poor proxy here — the heaviest file is not
    # close to the largest — so such a run may finish lopsided. It corrects
    # itself: .rspec_parallel has every worker write its timings, so the next
    # run splits on real numbers.
    coverage = runtime_log_coverage
    strategy = coverage > RUNTIME_LOG_THRESHOLD ? 'runtime' : 'filesize'
    puts "splitting #{workers} ways by #{strategy}"
    if strategy == 'filesize' && coverage.positive?
      puts "  (#{RUNTIME_LOG} covers only #{(coverage * 100).round}% of the spec files — " \
           'too thin to sort by, so this run rebuilds it)'
    end

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
