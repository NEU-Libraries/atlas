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
    # container re-parent changes the ancestor chain embedded in every
    # descendant, and none of them is re-saved. Both call ResponseCache directly.
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

      def save(resource:, **)
        @persister.save(resource: resource, **).tap { |saved| evict(saved) }
      end

      def save_all(resources:, **)
        @persister.save_all(resources: resources, **).tap do |saved|
          evict_many(Array(saved))
        end
      end

      # The owner is read BEFORE the delete: a Blob reaches its FileSet only
      # through the FileSet's member_ids, and that edge may not survive the
      # delete.
      def delete(resource:, **)
        owners = owner_noids([resource])
        @persister.delete(resource: resource, **).tap { |deleted| evict(deleted, owners) }
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

        def evict(resource, owners = nil)
          evict_many([resource], owners)
        end

        def evict_many(resources, owners = nil)
          return unless ResponseCache.enabled?

          noids = resources.filter_map { |resource| resource.try(:noid).presence }
          ResponseCache.evict_many((noids + (owners || owner_noids(resources))).uniq)
        rescue StandardError => e
          Rails.logger.warn("ResponseCache eviction failed: #{e.class} #{e.message}")
        end

        # A FileSet or Blob write changes the file listings cached under its
        # Work's NOID, and nothing on that path re-saves the Work. Batched, so a
        # save_all costs at most two parent reads; see docs/read-performance.md.
        def owner_noids(resources)
          return [] unless ResponseCache.enabled?

          leaves = resources.select { |resource| resource.is_a?(Blob) || resource.is_a?(FileSet) }
          return [] if leaves.empty?

          file_sets = leaves.grep(FileSet) + parents_of(leaves.grep(Blob)).grep(FileSet)
          parents_of(file_sets).filter_map { |owner| owner.try(:noid).presence }
        rescue StandardError => e
          Rails.logger.warn("ResponseCache owner lookup failed: #{e.class} #{e.message}")
          []
        end

        # A Blob saved before it joins its FileSet has no parent yet. The
        # FileSet save that follows finds the Work, so nothing is missed.
        def parents_of(resources)
          persisted = resources.select { |resource| resource.id.present? }
          return [] if persisted.empty?

          Atlas.query.custom_queries.find_many_parents(resources: persisted).values
        end
    end
  end
end
