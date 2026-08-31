# frozen_string_literal: true

# Puma can serve each request in a thread from an internal thread pool.
# The `threads` method setting takes two numbers: a minimum and maximum.
# Any libraries that use thread pools should be configured to match
# the maximum value specified for Puma. Default is set to 5 threads for minimum
# and maximum; this matches the default thread size of Active Record.
#
max_threads_count = ENV.fetch('RAILS_MAX_THREADS', 5)
min_threads_count = ENV.fetch('RAILS_MIN_THREADS') { max_threads_count }
threads min_threads_count, max_threads_count

# Specifies the `worker_timeout` threshold that Puma will use to wait before
# terminating a worker in development environments.
#
worker_timeout 3600 if ENV.fetch('RAILS_ENV', 'development') == 'development'

# Specifies the `port` that Puma will listen on to receive requests; default is 3000.
#
port ENV.fetch('PORT', 3000)

# Specifies the `environment` that Puma will run in.
#
environment ENV.fetch('RAILS_ENV', 'development')

# Specifies the `pidfile` that Puma will use.
pidfile ENV.fetch('PIDFILE', 'tmp/pids/server.pid')

# Cerberus fans a Work show page out into four concurrent Atlas reads, and
# threads cannot serve those in parallel: the GVL serialises Ruby execution
# within a process, and this read path is allocation-bound rather than IO-bound.
# Only workers give the batch real parallelism, and the count has to match the
# fan-out — two workers recover 6% of it, four recover about 45%.
#
# The default of 0 is single mode, so development and the test suite are
# untouched; staging and production opt in with WEB_CONCURRENCY. Each worker
# carries its own Active Record pool, so the connection ceiling is
# WEB_CONCURRENCY * RAILS_MAX_THREADS, and its own memory: four workers measured
# 581MB against single mode's 193MB. Size the host for that before opting in.
web_concurrency = ENV.fetch('WEB_CONCURRENCY', 0).to_i
workers web_concurrency

# Puma already preloads in cluster mode, so this states the default rather than
# changing it — worth being explicit, because the memory figure above depends on
# it. Measured at four workers it saves 126MB, or 95MB once YJIT is on: YJIT
# compiles after the fork, so its code region is per-worker and copy-on-write
# has nothing to share. YJIT costs about 200MB across four workers either way.
preload_app! if web_concurrency.positive?

# Allow puma to be restarted by `bin/rails restart` command.
plugin :tmp_restart
