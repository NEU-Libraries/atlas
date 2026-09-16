# frozen_string_literal: true

# Sets environment variables for the duration of a block, then restores them.
#
# Used by the specs covering the per-worker seams (SolrCore, TestStorage), which
# read ENV directly rather than through a stubbable object. Restoring the
# previous values matters more than usual here: the run doing the asserting may
# itself be a parallel worker, and losing its own TEST_ENV_NUMBER would point
# every later example at another worker's stores.
def with_env(values)
  previous = values.keys.index_with { |key| ENV.fetch(key, nil) }
  values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  yield
ensure
  previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
end
