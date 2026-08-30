# frozen_string_literal: true

module Valkyrie
  module Persistence
    # Wraps the composite persister so that writing a resource drops its cached
    # responses.
    #
    # This is the seam every write already passes through — the creators, the
    # lifecycle verbs, the thumbnail and derivative setters, the re-parent, the
    # purge — so eviction does not depend on each controller remembering to ask
    # for it. Two write paths still need an explicit hook because they change a
    # cached body WITHOUT saving the resource whose body it is: Modsable#mods_json=
    # writes the metadata_mods row before the persister sees anything, and a
    # container re-parent changes the ancestor chain embedded in descendant
    # Works that are never re-saved. Both call ResponseCache directly.
    #
    # Eviction never fails a write. A cache that cannot be reached is a
    # performance problem; a save that rolls back because of one is a data
    # problem, and the TTL bounds the damage either way.
    class CacheEvictingPersister
      # `delete` hands back the deleted resource, and the wrapped persisters
      # answer the saved one, so every method here returns the inner result
      # untouched — this decorator adds a side effect, not a value.
      def initialize(persister)
        @persister = persister
      end

      def save(resource:, **opts)
        @persister.save(resource: resource, **opts).tap { |saved| evict(saved) }
      end

      def save_all(resources:, **opts)
        @persister.save_all(resources: resources, **opts).tap do |saved|
          evict_many(Array(saved))
        end
      end

      def delete(resource:, **opts)
        @persister.delete(resource: resource, **opts).tap { |deleted| evict(deleted) }
      end

      def wipe!(...)
        @persister.wipe!(...)
      end

      # Anything else on the Valkyrie persister contract passes straight
      # through, so wrapping cannot narrow the interface.
      def method_missing(name, ...)
        @persister.respond_to?(name) ? @persister.public_send(name, ...) : super
      end

      def respond_to_missing?(name, include_private = false)
        @persister.respond_to?(name, include_private) || super
      end

      private

        def evict(resource)
          evict_many([resource])
        end

        def evict_many(resources)
          noids = resources.filter_map { |resource| resource.try(:noid).presence }
          ResponseCache.evict_many(noids)
        rescue StandardError => e
          Rails.logger.warn("ResponseCache eviction failed: #{e.class} #{e.message}")
        end
    end
  end
end
