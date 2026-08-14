# frozen_string_literal: true

# A Compilation (DRS "Set"): a personal, curated, recipe-based grouping of
# Works and Collections. The recipe is three noid lists — include-collection
# (transitive), include-work (individual), exclude-work (set-aside) — that
# CompilationContentsQuery resolves against Solr at read time; nothing is
# materialized.
#
# Deliberately AR, not Valkyrie: ephemeral / non-preservation, so no OCFL
# envelope, no MODS, no NOID-bearing Solr doc. The public id IS a minted
# NOID (same ::Minter, same namespace as resource noids — no collisions by
# construction) so Cerberus /sets/:id URLs match /works/:id; the bigint pk
# is never exposed (audit rows store it internally, no endpoint surfaces
# it). All controller lookups go find_by!(noid:).
class Compilation < ApplicationRecord
  include Compilation::ACL

  # The membership join models nest under this class
  # (Compilation::CollectionInclusion et al.). Both halves of the wiring are
  # Rails convention: association class names resolve inside this namespace
  # first (:collection_inclusions → Compilation::CollectionInclusion), and
  # models nested in an AR class get the singular parent table name as a
  # prefix — so the children land on the compilation_* tables the migration
  # created with no table_name configuration at all.
  # dependent: :delete_all is belt-and-suspenders over the FK ON DELETE
  # CASCADE — keeps AR-initiated destroys correct even outside Postgres.
  has_many :collection_inclusions, dependent: :delete_all
  has_many :work_inclusions,       dependent: :delete_all
  has_many :exclusions,            dependent: :delete_all

  validates :title, :depositor, presence: true

  before_create { self.noid ||= Minter.mint }

  # v1's ListSets passed no `rows` and inherited Solr's default of 10, so it
  # would have truncated silently at the eleventh published set. The cap here
  # is explicit and generous, and it bounds the per-page setSpec resolution
  # too (OAISetMembershipQuery runs one Solr query per published set).
  PUBLISHED_LIMIT = 500

  # The OAI-PMH sets (GET /oai?verb=ListSets). Publishing a Set is an external
  # commitment — a harvester walks it and copies what it finds into another
  # catalogue — so the verb pair is admin-only and the recipe routes start
  # emitting audit rows once the flag is on. Ordered by noid so ListSets and a
  # record's setSpec list agree from one page to the next.
  scope :published, -> { where(published: true).order(:noid).limit(PUBLISHED_LIMIT) }

  # Grant-scoped listing: Sets where the principal is a *grantee* but not the
  # owner — the "Shared with me" / "Editable by me" surfaces. Owned Sets are
  # always excluded (the UI lists those under "My Sets"); the caller's own
  # owner-scoped listing stays a separate query. Newest-first, like the
  # owner scope.
  #
  # The grant axes mirror the Ability per-row checks (Ability#group_acl_grants?
  # / #compilation_readable?), evaluated in SQL here instead of Ruby:
  #   - edit_users contains the caller's NUID, OR
  #   - edit_groups intersects the caller's groups, AND (when include_read)
  #   - read_groups intersects the caller's groups (edit grants imply read).
  # `include_read: false` is the "editable by me" bucket (edit grants only);
  # `true` is "shared with me" (read grants too). Group membership is resolved
  # server-side from the authenticated principal — same source the Ability
  # consults — so no group list crosses the wire.
  #
  # A principal with neither a NUID nor any groups (e.g. guest) matches no
  # grant and gets an empty relation.
  def self.granted_to(nuid:, groups:, include_read:)
    groups  = Array(groups)
    clauses = []
    binds   = []

    if nuid.present?
      clauses << 'edit_users && ARRAY[?]::varchar[]'
      binds   << [nuid]
    end
    if groups.any?
      clauses << 'edit_groups && ARRAY[?]::varchar[]'
      binds   << groups
      if include_read
        clauses << 'read_groups && ARRAY[?]::varchar[]'
        binds   << groups
      end
    end

    return none if clauses.empty?

    scope = where("(#{clauses.join(' OR ')})", *binds)
    scope = scope.where.not(depositor: nuid) if nuid.present?
    scope.order(created_at: :desc)
  end

  def included_collections
    collection_inclusions.order(:id).pluck(:resource_noid)
  end

  def included_works
    work_inclusions.order(:id).pluck(:resource_noid)
  end

  def excluded_works
    exclusions.order(:id).pluck(:resource_noid)
  end
end
