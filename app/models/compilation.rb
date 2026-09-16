# frozen_string_literal: true

# A recipe of three noid lists that CompilationContentsQuery resolves against
# Solr at read time; nothing is materialized. Deliberately AR and not
# Valkyrie, so no OCFL envelope and no MODS. The public id is still a minted
# NOID from the same Minter, and the bigint pk is never exposed -- so every
# controller lookup goes find_by!(noid:). See docs/compilations.md.
class Compilation < ApplicationRecord
  include Compilation::ACL

  # Nesting these under the class is what puts them on the compilation_*
  # tables with no table_name configuration. delete_all is
  # belt-and-suspenders over the FK's ON DELETE CASCADE.
  has_many :collection_inclusions, dependent: :delete_all
  has_many :work_inclusions,       dependent: :delete_all
  has_many :exclusions,            dependent: :delete_all

  validates :title, :depositor, presence: true

  before_create { self.noid ||= Minter.mint }

  # Explicit because the default bit: passing no `rows` inherits Solr's 10
  # and truncates SILENTLY at the eleventh published set. Also bounds the
  # per-page setSpec resolution, one Solr query per published set.
  PUBLISHED_LIMIT = 500

  # Ordered by noid so ListSets and a setSpec list agree across pages.
  scope :published, -> { where(published: true).order(:noid).limit(PUBLISHED_LIMIT) }

  # Sets where the principal is a GRANTEE but not the owner. The axes mirror
  # Ability#group_acl_grants? and #compilation_readable?, in SQL rather than
  # Ruby; group membership is resolved server-side, so no group list crosses
  # the wire.
  #
  # A principal with neither a NUID nor any groups matches no grant and gets
  # an EMPTY relation rather than everything.
  def self.granted_to(nuid:, groups:, include_read:)
    grants = grant_clauses(nuid, Array(groups), include_read)
    return none if grants.empty?

    scope = where("(#{grants.map(&:first).join(' OR ')})", *grants.map(&:last))
    scope = scope.where.not(depositor: nuid) if nuid.present?
    scope.order(created_at: :desc)
  end

  # One [clause, bind] pair per applicable axis. Overlap (&&) is the test.
  def self.grant_clauses(nuid, groups, include_read)
    pairs = []
    pairs << ['edit_users && ARRAY[?]::varchar[]', [nuid]] if nuid.present?
    if groups.any?
      pairs << ['edit_groups && ARRAY[?]::varchar[]', groups]
      pairs << ['read_groups && ARRAY[?]::varchar[]', groups] if include_read
    end
    pairs
  end
  private_class_method :grant_clauses

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
