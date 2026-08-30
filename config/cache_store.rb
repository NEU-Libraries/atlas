# frozen_string_literal: true

# The cache_store configuration shared by the environments that have a real one.
#
# Extracted rather than copied into each environment file, because staging
# exists to tell you what production will do. Two copies drift, and a staging
# cache configured differently from production's is a staging environment that
# has quietly stopped answering that question — which is the same failure that
# put staging on development-style code loading to begin with.
#
# Not autoloaded: config/ is outside the autoload paths, so both environment
# files require_relative this one.
module AtlasCacheStore
  # Rails takes `config.cache_store = :name, options`, which is an array
  # assignment — so returning the pair is the same thing written once.
  def self.redis
    [:redis_cache_store, {
      url:       ENV.fetch('REDIS_URL', 'redis://redis:6379/0'),
      namespace: 'atlas',
      # A cache outage must not take reads down: on a connection error Rails
      # treats the store as a miss and renders, which is the pre-cache
      # behaviour. It is logged rather than swallowed, because a Redis that is
      # simply absent otherwise looks exactly like a cache that is working.
      error_handler:      lambda { |method:, returning:, exception:|
        Rails.logger.warn("cache #{method} failed: #{exception.class} #{exception.message} -> #{returning.inspect}")
      },
      connect_timeout:    1,
      read_timeout:       0.2,
      write_timeout:      0.2,
      reconnect_attempts: 1
    }]
  end
end
