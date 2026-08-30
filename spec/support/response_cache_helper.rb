# frozen_string_literal: true

# The test environment runs on :null_store, so ResponseCache reports itself
# disabled and every read renders — which is what the rest of the suite wants,
# because a cached body would mask a change to the view it came from.
#
# Tag an example `:response_cache` to give it a real (per-example, in-memory)
# store instead. Redis is not used here on purpose: these specs are about what
# gets stored and what evicts it, and an in-process store makes both directly
# inspectable without a service dependency.
# Swapped rather than stubbed: an `around` hook runs outside the per-example
# rspec-mocks lifecycle, so `allow(Rails).to receive(:cache)` is not available
# here. Rails.cache= is a plain writer, and restoring it in `ensure` keeps the
# swap from leaking into the next example.
RSpec.configure do |config|
  config.around(:each, :response_cache) do |example|
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original
  end
end

# The entries ResponseCache is currently holding, for asserting on eviction
# without reaching into key construction.
def cached_scopes_for(noid)
  ResponseCache::SCOPES.product(ResponseCache::AUDIENCES).filter_map do |scope, audience|
    key = ResponseCache.key(scope: scope, noid: noid, audience: audience)
    "#{scope}/#{audience}" if Rails.cache.exist?(key)
  end
end
