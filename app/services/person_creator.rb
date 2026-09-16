# frozen_string_literal: true

# Creates a Person (curatorial identity). Deliberately lean -- a Person is
# identity, not preserved content, so unlike the other creators this seeds no
# descriptive-metadata FileSet, no MODS template, and no OCFL envelope. The
# personal root it mints IS a preserved Collection. See docs/people.md.
#
# Born public-readable, and publicized explicitly because a Person has no
# parent to inherit a public ACL from. Without it, gated discovery drops the
# Person from every non-admin search.
#
# One Person per NUID is the invariant, but the uniqueness guard lives in the
# controller so this stays a pure constructor.
class PersonCreator < ApplicationService
  def initialize(nuid:, display_name:, bio: nil, orcid: nil,
                 actor_nuid: nil, on_behalf_of_nuid: nil)
    @nuid              = nuid
    @display_name      = display_name
    @bio               = bio
    @orcid             = orcid
    @actor_nuid        = actor_nuid
    @on_behalf_of_nuid = on_behalf_of_nuid
  end

  def call
    person = Person.new(nuid: @nuid, display_name: @display_name, bio: @bio, orcid: @orcid)
    # Public read before the first composite save, so AccessControlsIndexer projects it (see class note).
    person.publicize
    person = Atlas.persister.save(resource: person)
    # Eagerly mint the personal root so it always exists by the time this Person
    # publishes (see PersonalRootCreator). An unattributed system side effect —
    # no actor passed, so it emits no structural audit of its own.
    person.personal_root_id = PersonalRootCreator.call(nuid: @nuid).noid
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
