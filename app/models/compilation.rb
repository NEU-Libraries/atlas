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
  include CompilationPermissions

  # dependent: :delete_all is belt-and-suspenders over the FK ON DELETE
  # CASCADE — keeps AR-initiated destroys correct even outside Postgres.
  has_many :collection_inclusions, class_name: 'CompilationCollectionInclusion', dependent: :delete_all
  has_many :work_inclusions,       class_name: 'CompilationWorkInclusion',       dependent: :delete_all
  has_many :exclusions,            class_name: 'CompilationExclusion',           dependent: :delete_all

  validates :title, :depositor, presence: true

  before_create { self.noid ||= Minter.mint }

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
