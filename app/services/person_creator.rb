# frozen_string_literal: true

# Creates a Person (curatorial identity). Deliberately lean — a Person is
# identity/authority, not preserved content, so unlike WorkCreator /
# CollectionCreator this does NOT seed a descriptive-metadata FileSet, write a
# MODS template, write an OCFL preservation envelope, or inherit any parent
# permissions. It saves the resource (Postgres + Solr) and emits the structural
# create audit row.
#
# One Person per NUID is the correlation invariant; the uniqueness guard lives
# at the controller (PeopleController#create -> 409) so this stays a pure
# constructor usable by specs / internal callers.
class PersonCreator < ApplicationService
  # rubocop:disable Metrics/ParameterLists
  def initialize(nuid:, display_name:, bio: nil, orcid: nil, title: nil,
                 actor_nuid: nil, on_behalf_of_nuid: nil)
    # rubocop:enable Metrics/ParameterLists
    @nuid              = nuid
    @display_name      = display_name
    @bio               = bio
    @orcid             = orcid
    @title             = title
    @actor_nuid        = actor_nuid
    @on_behalf_of_nuid = on_behalf_of_nuid
  end

  def call
    person = Atlas.persister.save(resource: Person.new(
      nuid: @nuid, display_name: @display_name, bio: @bio, orcid: @orcid, title: @title
    ))
    emit_audit_event!(person)
    person
  end

  private

    def emit_audit_event!(person)
      return if @actor_nuid.blank?

      AuditEventWriter.record(
        resource:          person,
        actor_nuid:        @actor_nuid,
        on_behalf_of_nuid: @on_behalf_of_nuid,
        action:            'create',
        change_type:       'structural',
        event_source:      'controller'
      )
    end
end
