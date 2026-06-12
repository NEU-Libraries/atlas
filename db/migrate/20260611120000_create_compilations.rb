# frozen_string_literal: true

# Compilations (DRS "Sets"): personal, curated, recipe-based groupings of
# Works and Collections. Ephemeral / non-preservation by design — they join
# the AR tier (User / AuditEvent / IdempotencyKey), not the Valkyrie tier:
# no OCFL envelope, no MODS, no Solr doc for the Compilation itself. The
# public id is a minted NOID (same minter/namespace as resource noids) so
# Cerberus /sets/:id URLs match /works/:id; the bigint pk is never exposed.
# See gap_reports/compilations_atlas_implementation_plan.md.
class CreateCompilations < ActiveRecord::Migration[7.0]
  def change
    create_table :compilations do |t|
      t.string :noid,        null: false          # minted public id
      t.string :title,       null: false
      t.text   :description
      t.string :depositor,   null: false          # curator NUID (provenance vocabulary)
      t.string :edit_users,  array: true, default: [], null: false
      t.string :read_groups, array: true, default: [], null: false
      t.string :edit_groups, array: true, default: [], null: false
      t.timestamps
      t.index :noid, unique: true
      t.index :depositor
    end

    create_membership_tables
  end

  private

    # Three identical membership tables — separate tables (not one polymorphic
    # row + kind column) so each carries its own uniqueness constraint and the
    # reverse query ("which Sets include Collection X?") stays an index hit.
    # Join rows store the noid — the API-addressable id callers already send
    # and the key ancestor_ids_ssim speaks; the uuid hop happens inside the
    # contents query where it's needed.
    def create_membership_tables
      %i[compilation_collection_inclusions
         compilation_work_inclusions
         compilation_exclusions].each do |table|
        create_table table do |t|
          t.references :compilation, null: false, foreign_key: { on_delete: :cascade }
          t.string :resource_noid, null: false
          t.timestamps
          t.index %i[compilation_id resource_noid], unique: true, name: "idx_#{table}_uniq"
          t.index :resource_noid
        end
      end
    end
end
