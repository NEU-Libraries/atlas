# frozen_string_literal: true

# Hard-deletes a resource: its Postgres row, its Solr document, and the OCFL
# object holding its preservation envelope and its bytes. This is the only
# path in Atlas that removes preserved bytes, which is why :destroy is
# admin-only and why the audit row is written before anything is removed —
# the row is the last remaining evidence that the object existed.
#
# A Work, Collection or Community cascades into its own FileSets and their
# Blobs. Those are parts of the resource, not things a curator manages
# separately, and every container carries at least one (the descriptive
# metadata FileSet that WorkCreator and its siblings mint). The cascade stops
# there: a container that still holds a Work or a sub-container is refused by
# the controller, so a tree comes down leaf-first and each step is audited.
class ResourcePurger < ApplicationService
  def initialize(resource:, actor_nuid: nil, on_behalf_of_nuid: nil)
    @resource          = resource
    @actor_nuid        = actor_nuid
    @on_behalf_of_nuid = on_behalf_of_nuid
  end

  def call
    targets = [@resource] + descendants(@resource)
    emit_audit_event!(targets)

    # Deepest first, so a failure part-way through leaves a resolvable parent
    # with fewer children rather than children whose parent no longer exists.
    targets.reverse_each do |resource|
      detach_linked_members!(resource)
      purge_storage(resource)
      Atlas.persister.delete(resource: resource)
    end

    targets.map(&:noid)
  end

  private

    # A linked membership is stored on the Work, not on the Collection it
    # points into, so purging the Collection would otherwise leave every
    # linking Work holding an id that resolves to nothing. Structural children
    # need no equivalent, because the controller refuses a container that has
    # any.
    def detach_linked_members!(resource)
      linking_works(resource).each do |work|
        work.a_linked_member_of = Array(work.a_linked_member_of).reject { |id| id.to_s == resource.id.to_s }
        Atlas.persister.save(resource: work)
      end
    end

    def linking_works(resource)
      Atlas.query.find_inverse_references_by(resource: resource, property: :a_linked_member_of).to_a
    rescue KeyError
      []
    end

    def descendants(resource)
      case resource
      when Blob    then []
      when FileSet then children_of_type(resource, Blob)
      else children_of_type(resource, FileSet).flat_map { |fs| [fs] + descendants(fs) }
      end
    end

    def children_of_type(resource, klass)
      resource.children.select { |child| child.is_a?(klass) }
    end

    # One OCFL object per NOID holds both the resource's preservation envelope
    # and, for a Blob, its bytes — so a single delete per resource covers both.
    def purge_storage(resource)
      Valkyrie.config.storage_adapter.delete_object(key: resource.noid)
    end

    # FileSet and Blob are absent from AuditEvent::RESOURCE_TYPES, so their
    # removal is recorded in the `purged` manifest of the ancestor's row rather
    # than in one of their own.
    def emit_audit_event!(targets)
      return if @actor_nuid.blank?
      return unless AuditEvent::RESOURCE_TYPES.include?(@resource.class.name)

      AuditEventWriter.record(
        resource:          @resource,
        actor_nuid:        @actor_nuid,
        on_behalf_of_nuid: @on_behalf_of_nuid,
        action:            'destroy',
        change_type:       'lifecycle',
        event_source:      'controller',
        payload:           { purged: targets.map(&:noid) }
      )
    end
end
