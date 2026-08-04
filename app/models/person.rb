# frozen_string_literal: true

# A neutral curatorial identity, distinct from the auth-side `users` rows.
#
# One human typically has several `users` rows (student/staff/faculty) sharing
# a NUID; a Person correlates them by that shared NUID and carries the
# authoritative, librarian-editable `display_name` (the SSO-fed `users.name` is
# frequently wrong and is clobbered on every login, so the correction must live
# on a stable object). Persons also declare community affiliations, which drive
# which community genre-showcases the publish conduit targets.
#
# Lean by design — "Employee, done right": identity + affiliation, plus a single
# personal-root Collection (see personal_root_id). No per-person collection
# *graph*, no fan-out — one root, not v1's 8-folders-per-person sprawl. The
# Person itself is (decision) Postgres + Solr only — curatorial identity, not
# preserved content, so it writes no OCFL envelope and seeds no
# descriptive-metadata FileSet (its personal root, an ordinary Collection, does).
# It lives in orm_resources alongside Community/Collection/Work and reaches
# ordinary catalog results: Cerberus excludes file-level types by denylist
# (-FileSet, -Blob, -Delegate), which a Person passes. So a Person doc has to
# carry the same discovery projections every other result carries — see
# PersonIndexer for the People-surface fields and SortIndexer for the sort title.
class Person < Resource
  # The correlation key. Unique among Persons (enforced at create — one Person
  # per NUID); the public address for the People surface (/people/:nuid).
  attribute :nuid, Valkyrie::Types::String

  # AUTHORITATIVE display name — librarian-editable, never re-synced from SSO.
  attribute :display_name, Valkyrie::Types::String

  attribute :bio,   Valkyrie::Types::String.optional
  attribute :orcid, Valkyrie::Types::String.optional

  # Librarian-declared Person↔Community edges (Valkyrie ids). Mutated only via
  # the audited add/remove affiliation actions.
  attribute :affiliated_community_ids, Valkyrie::Types::Set.of(Valkyrie::Types::ID)

  # The Person's stable personal-root Collection — the structural parent the
  # publish conduit writes a depositor's own Works under (mirrors v1's per-
  # Employee "User Root", but one root per Person, affiliation-independent).
  # Minted eagerly by PersonCreator (PersonalRootCreator) and never moved when
  # affiliations change. Stores the root's NOID (a plain string — the public id,
  # like nuid; NOT a Valkyrie::Types::ID, which is the internal-id wrapper
  # affiliated_community_ids holds and the decorator has to resolve to NOIDs),
  # so the read path emits it with no resolve query and Cerberus reads it
  # straight off the JSON. Optional so a Person can exist pre-mint (backfill /
  # pre-existing rows).
  attribute :personal_root_id, Valkyrie::Types::String.optional

  attribute :type, Valkyrie::Types::String.default(Classification.person.name.freeze)
end
