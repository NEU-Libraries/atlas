# frozen_string_literal: true

require 'active_support/core_ext/integer/time'
require_relative '../cache_store'

# Staging mirrors production wherever the difference would change what staging
# can tell you, and differs only where a pre-production environment needs to be
# more forthcoming than a public one.
#
# The settings that must NOT be taken from development are the code-loading
# ones. With reloading on, Rails' reload interlock serialises concurrent
# requests, and Cerberus issues four Atlas reads at once for a Work show page —
# so the interlock turns that batch from a saving into a penalty. Measured, the
# same four calls cost ~182ms concurrent with reloading on against ~85ms
# eager-loaded. Staging forked from development.rb is the reason this file
# exists; see ~/docs/staging-ttfb-parity.md.
#
# Running staging as production instead would fix the latency and break the
# reset: MaintenanceController::RESETTABLE_ENVS admits staging but never
# production, and staging depends on that reset to rebuild its stock fixtures.
# A real staging environment is what keeps both.
Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests — the whole point of this file.
  config.cache_classes = true

  # Eager load code on boot, so a threaded server is not serialised by the
  # reload interlock.
  config.eager_load = true

  # Unlike production. Staging is where a failure should be legible, and its
  # audience is the team rather than the public.
  config.consider_all_requests_local = true

  # Disable serving static files from the `/public` folder by default since
  # Apache or NGINX already handles this.
  config.public_file_server.enabled = ENV['RAILS_SERVE_STATIC_FILES'].present?

  config.log_level = ENV.fetch('RAILS_LOG_LEVEL', 'info').to_sym

  # Prepend all log lines with the following tags.
  config.log_tags = [:request_id]

  # The same store production uses, from one definition — see config/cache_store.rb.
  # Staging needs a Redis service reachable at REDIS_URL; without one the store
  # logs and reads as a miss, so the app is correct but runs at pre-cache speed.
  config.cache_store = AtlasCacheStore.redis

  config.action_mailer.perform_caching = false

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Unlike production, which silences these. Staging is the last place a
  # deprecation can be seen before it becomes a production failure.
  config.active_support.report_deprecations = true

  # Use default logging formatter so that PID and timestamp are not suppressed.
  config.log_formatter = ::Logger::Formatter.new

  if ENV['RAILS_LOG_TO_STDOUT'].present?
    logger           = ActiveSupport::Logger.new($stdout)
    logger.formatter = config.log_formatter
    config.logger    = ActiveSupport::TaggedLogging.new(logger)
  end

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false
end
