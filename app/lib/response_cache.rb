# frozen_string_literal: true

# Cached rendered responses for the read endpoints whose body is a pure
# function of one resource's state.
#
# Atlas's read cost is allocation-bound, not database-bound: resolving a Work
# and authorizing it costs ~0.7ms, while decorating it and running the jbuilder
# costs ~9ms. So the thing worth caching is the rendered body, and the thing
# not worth caching is the authorization.
#
# **Authorization always runs against the live resource.** The controller
# resolves the record and calls `authorize!` before it ever consults this
# cache, so a cached body can only be handed to a caller the current ACL
# admits. Storing the ACL here to skip that lookup would buy 0.7ms and
# introduce a window in which a just-narrowed resource still reads as public;
# that trade is not worth taking.
#
# Scopes are enumerated and validated. A caller that caches under a scope this
# class does not know about raises, because eviction works by walking SCOPES —
# an endpoint cached under an unlisted scope would never be evicted, and a
# silently stale ACL-shaped payload is the failure mode this codebase can least
# afford. Adding a cached endpoint means adding its scope here, and its first
# spec fails until you do.
class ResponseCache
  NAMESPACE = 'atlas/response/v1'

  # One entry per (scope, noid, audience). The format is folded into the scope
  # because /works/:id/mods answers three of them and they must not collide.
  SCOPES = %w[
    works.show
    works.mods.json
    works.mods.html
    works.mods.xml
    works.mets
    works.assets
    works.file_sets
    collections.show
    collections.mods.json
    collections.mods.html
    collections.mods.xml
    communities.show
    communities.mods.json
    communities.mods.html
    communities.mods.xml
    people.show
    resources.permissions
  ].freeze

  # Most bodies are identical for every caller the gate admits. The two asset
  # listings are not: works/_asset.json.jbuilder withholds the `permission`
  # group list from guests, to avoid naming Grouper groups to public traffic.
  # That is the ONLY caller input in any cached view, and it is a boolean, so
  # two buckets cover it rather than a key per principal.
  AUDIENCES = %i[any guest authenticated].freeze

  # Eviction is the real mechanism; this is the backstop for a write path that
  # somehow does not reach one. Short enough that a missed eviction is a blip.
  DEFAULT_TTL = 1.hour

  Entry = Struct.new(:status, :body, :content_type, keyword_init: true)

  class << self
    # Off unless a real store is configured, so the test environment's
    # :null_store and a misconfigured deploy both fall through to rendering
    # rather than silently caching nothing at a cost.
    def enabled?
      return false if ENV['ATLAS_RESPONSE_CACHE'] == 'off'
      return false if Rails.cache.nil? || Rails.cache.is_a?(ActiveSupport::Cache::NullStore)

      true
    end

    def read(scope:, noid:, audience: :any)
      return nil unless enabled?

      stored = Rails.cache.read(key(scope: scope, noid: noid, audience: audience))
      return nil if stored.nil?

      Entry.new(**stored)
    end

    def write(scope:, noid:, audience: :any, **entry)
      return unless enabled?

      Rails.cache.write(key(scope: scope, noid: noid, audience: audience),
                        Entry.new(**entry).to_h, expires_in: ttl)
    end

    # Drop every representation of a resource: all scopes, all audiences, in
    # one round trip. Deliberately not selective — working out which scopes a
    # given write could have touched is the kind of bookkeeping that rots, and
    # deleting a key that was never there costs nothing.
    def evict(noid)
      evict_many([noid])
    end

    def evict_many(noids)
      return unless enabled?

      keys = Array(noids).compact.flat_map do |noid|
        SCOPES.product(AUDIENCES).map { |scope, audience| key(scope: scope, noid: noid, audience: audience) }
      end
      return if keys.empty?

      Rails.cache.delete_multi(keys)
    end

    def key(scope:, noid:, audience:)
      raise ArgumentError, "unknown response cache scope #{scope.inspect}" unless SCOPES.include?(scope.to_s)
      unless AUDIENCES.include?(audience.to_sym)
        raise ArgumentError, "unknown response cache audience #{audience.inspect}"
      end

      "#{NAMESPACE}/#{scope}/#{noid}/#{audience}"
    end

    def ttl
      seconds = ENV['ATLAS_RESPONSE_CACHE_TTL'].to_i
      seconds.positive? ? seconds.seconds : DEFAULT_TTL
    end
  end
end
