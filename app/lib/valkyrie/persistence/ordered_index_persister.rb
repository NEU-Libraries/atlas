# frozen_string_literal: true

module Valkyrie
  module Persistence
    # Saves to Postgres, then indexes in Solr what Postgres holds, one Solr write
    # per resource at a time. Valkyrie's CompositePersister orders two saves of
    # one resource in Postgres but not in Solr, so the slower of two saves could
    # index the older state last. See docs/write-safety.md.
    class OrderedIndexPersister
      attr_reader :source, :index

      def initialize(source, index)
        @source = source
        @index  = index
      end

      # Postgres's lock token goes back to the caller. Solr gets none, as in
      # Valkyrie's composite, because Solr keeps its own versions.
      def save(resource:, external_resource: false)
        source.save(resource: resource, external_resource: external_resource).tap { |saved| index!(saved) }
      end

      def save_all(resources:)
        resources.map { |resource| save(resource: resource) }
      rescue Valkyrie::Persistence::StaleObjectError
        raise Valkyrie::Persistence::StaleObjectError, 'One or more resources have been updated by another process.'
      end

      def delete(resource:)
        source.delete(resource: resource).tap do |deleted|
          AdvisoryLock.hold('index', deleted.id) { index.delete(resource: deleted) }
        end
      end

      def wipe!
        source.wipe!
        index.wipe!
      end

      # Reads the resource under the lock, so a writer that waited indexes the
      # latest save, not its own. A resource purged meanwhile indexes nothing,
      # because a write would bring back the document the purge removed.
      def index!(resource)
        AdvisoryLock.hold('index', resource.id) do
          fresh = source.adapter.query_service.find_by(id: resource.id)
          fresh.clear_optimistic_lock_token!
          index.save(resource: fresh, external_resource: true)
        rescue Valkyrie::Persistence::ObjectNotFoundError
          nil
        end
      end
    end
  end
end
