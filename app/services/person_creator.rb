# frozen_string_literal: true

# Creates a Person (curatorial identity). Deliberately lean — a Person is
# identity/authority, not preserved content, so unlike WorkCreator /
# CollectionCreator this does NOT seed a descriptive-metadata FileSet, write a
# MODS template, write an OCFL preservation envelope, or inherit any parent
# permissions. It saves the resource (Postgres + Solr) and emits the structural
# create audit row.
#
# Born public-readable: People are public directory entries (v1's Faculty &
# Staff was world-browsable). Person has no parent to inherit a public ACL from
# (the way a Work does), so the creator publicizes it (add_read_group('public'))
# — the standard AccessControlsIndexer then projects read_access_group_ssim:
# ['public'], without which gated discovery ({!terms f=read_access_group_ssim}
# public,…) drops the Person from every non-admin search.
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
    person = Person.new(nuid: @nuid, display_name: @display_name, bio: @bio, orcid: @orcid, title: @title)
    # Public read before the first composite save, so AccessControlsIndexer projects it (see class note).
    person.publicize
    person = Atlas.persister.save(resource: person)
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
