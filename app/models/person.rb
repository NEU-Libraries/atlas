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
# Lean by design — "Employee, done right": identity + affiliation only. No
# per-person collection graph, no creation job, no fan-out, and (decision)
# Postgres + Solr only — Person is curatorial identity, not preserved content,
# so it writes no OCFL envelope and seeds no descriptive-metadata FileSet.
# It lives in orm_resources alongside Community/Collection/Work but is scoped
# OUT of the catalog default by its internal_resource (Cerberus type-allowlists
# Work/Collection/Community); see PersonIndexer for the People-surface
# projection.
class Person < Resource
  # The correlation key. Unique among Persons (enforced at create — one Person
  # per NUID); the public address for the People surface (/people/:nuid).
  attribute :nuid, Valkyrie::Types::String

  # AUTHORITATIVE display name — librarian-editable, never re-synced from SSO.
  attribute :display_name, Valkyrie::Types::String

  attribute :bio,   Valkyrie::Types::String.optional
  attribute :orcid, Valkyrie::Types::String.optional
  attribute :title, Valkyrie::Types::String.optional

  # Librarian-declared Person↔Community edges (Valkyrie ids). Mutated only via
  # the audited add/remove affiliation actions.
  attribute :affiliated_community_ids, Valkyrie::Types::Set.of(Valkyrie::Types::ID)

  attribute :type, Valkyrie::Types::String.default(Classification.person.name.freeze)
end
