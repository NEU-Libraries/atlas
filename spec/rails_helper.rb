# frozen_string_literal: true

require 'simplecov'

# Each parallel worker covers only its own shard, so it needs its own result
# name: SimpleCov keys .resultset.json by command name, and workers sharing one
# would overwrite each other instead of merging. With distinct names the last
# worker to exit writes a report merged across all of them.
SimpleCov.command_name("rspec#{ENV['TEST_ENV_NUMBER']}") if ENV.key?('TEST_ENV_NUMBER')

SimpleCov.start 'rails' do
  skip 'spec'
  skip 'vendor'
  skip 'app/channels'
  skip 'app/indexers'
  skip 'app/lib/atlas/vocab'
  # The floor is a property of the whole suite, so only a run of the whole suite
  # can judge it. Set here and lifted below for the runs that are subsets, which
  # would otherwise fail on arithmetic and say nothing about the code under test.
  #
  # SMOKE covers the runs a file count cannot see — `rake smoke` names a tag, so
  # rspec loads every spec file to find four examples in one of them.
  minimum_coverage 90 unless ENV['SMOKE']
end

# This file is copied to spec/ when you run 'rails generate rspec:install'
require 'spec_helper'
ENV['RAILS_ENV'] ||= 'test'
require_relative '../config/environment'
# Prevent database truncation if the environment is production
abort('The Rails environment is running in production mode!') if Rails.env.production?
require 'rspec/rails'
# Add additional requires below this line. Rails is not loaded until this point!

# Requires supporting ruby files with custom matchers and macros, etc, in
# spec/support/ and its subdirectories. Files matching `spec/**/*_spec.rb` are
# run as spec files by default. This means that files in spec/support that end
# in _spec.rb will both be required and run as specs, causing the specs to be
# run twice. It is recommended that you do not name files matching this glob to
# end with _spec.rb. You can configure this pattern with the --pattern
# option on the command line or in ~/.rspec, .rspec or `.rspec-local`.
#
# The following line is provided for convenience purposes. It has the downside
# of increasing the boot-up time by auto-requiring all files in the support
# directory. Alternatively, in the individual `*_spec.rb` files, manually
# require only the support files necessary.
#
Dir[Rails.root.join('spec/support/**/*.rb')].each { |f| require f }

# Checks for pending migrations and applies them before tests are run.
# If you are not using ActiveRecord, you can remove these lines.
begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip
end
RSpec.configure do |config|
  # Minting reaches a real, external Handle server, so the suite must never be
  # able to reach one. HandleClient reads its configuration from the
  # environment, and docker-compose sets those variables on the same `web`
  # service that runs the specs — so on a developer's configured machine the
  # suite would mint (and delete) live records. Clearing them here makes
  # HandleClient#configured? false for every example; the specs that exercise
  # minting inject a double or pass explicit arguments.
  #
  # HANDLE_RESOLVER_BASE reaches nothing, but it is cleared with the rest so
  # that the URL the minter writes into a document is the same on a developer's
  # machine as it is in CI.
  config.before(:suite) do
    %w[HANDLE_SERVER_URL HANDLE_PREFIX HANDLE_ADMIN_SECRET HANDLE_SSL_VERIFY
       HANDLE_RESOLVER_BASE CERBERUS_PUBLIC_BASE].each { |key| ENV.delete(key) }
  end

  # The preflight and the lock both run BEFORE the wipe, not after: the wipe is
  # the destructive step, so anything that could veto it has to run first. The
  # preflight checks which stores are about to be emptied; the lock stops a
  # second run from emptying them mid-flight.
  config.before(:suite) do
    SpecPreflight.assert_safe_to_wipe!
    ExclusiveRunLock.acquire!
  end

  # Lift the coverage floor for a run that loaded only part of the suite: a
  # developer naming a file or a directory, a parallel worker taking its shard,
  # or the OpenAPI regeneration pass, which loads the request specs alone and
  # under --dry-run executes none of them.
  #
  # Decided from what rspec loaded rather than from the command line, because no
  # reading of ARGV tells those apart from a whole-suite run: `rake spec` passes
  # the suite either as one --pattern glob or as an expanded list of every file,
  # depending on whether the glob is --pattern-compatible.
  #
  # Before the suite rather than after it, so the comparison describes the run
  # that is executing. SimpleCov reads the floor in an at_exit handler, so
  # setting it this early still takes effect.
  config.before(:suite) do
    SimpleCov.minimum_coverage(0) if config.files_to_run.size < Rails.root.glob('spec/**/*_spec.rb').size
  end

  config.before(:suite) do
    FileUtils.rm_rf(TestStorage.root)
    Atlas.persister.wipe!
    # AR-managed rows that integration specs commit outside the per-example
    # transaction (the Capybara::Server Puma thread holds its own connection
    # — most writes ARE rolled back via Rails 5+ connection sharing, but
    # rows from prior non-rspec HTTP activity against the same test DB are
    # not). Sweep at suite start so unit-level scopes (e.g. AuditEvent
    # `by_actor` in audit_event_spec) see only what the suite itself
    # creates.
    AuditEvent.delete_all
  end

  # Remove this line if you're not using ActiveRecord or ActiveRecord fixtures
  config.fixture_paths = [Rails.root.join('spec/fixtures')]

  # If you're not using ActiveRecord, or you'd prefer not to run each of your
  # examples within a transaction, remove the following line or assign false
  # instead of true.
  config.use_transactional_fixtures = true

  # You can uncomment this line to turn off ActiveRecord support entirely.
  # config.use_active_record = false

  # RSpec Rails can automatically mix in different behaviours to your tests
  # based on their file location, for example enabling you to call `get` and
  # `post` in specs under `spec/controllers`.
  #
  # You can disable this behaviour by removing the line below, and instead
  # explicitly tag your specs with their type, e.g.:
  #
  #     RSpec.describe UsersController, type: :controller do
  #       # ...
  #     end
  #
  # The different available types are documented in the features, such as in
  # https://rspec.info/features/6-0/rspec-rails
  config.infer_spec_type_from_file_location!

  # Filter lines from Rails gems in backtraces.
  config.filter_rails_from_backtrace!
  # arbitrary gems may also be filtered via:
  # config.filter_gems_from_backtrace("gem name")
end
