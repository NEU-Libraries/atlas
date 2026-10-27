# frozen_string_literal: true

# One row per OCFL object: the latest fixity check recorded for it. Derived and
# disposable: each object's logs/fixity.jsonl is the record, and
# `rake atlas:fixity:rebuild` recomputes this from those logs. See
# docs/fixity.md.
#
# Keyed by the object key (the resource NOID), like storage_footprints, because
# a check names an object, not a resource row.
class CreateFixityResults < ActiveRecord::Migration[8.1]
  def change
    create_table :fixity_results, id: false do |t|
      t.string :object_key, null: false, primary_key: true
      t.datetime :checked_at, null: false
      t.string :result, null: false
      t.string :version, null: false
      t.string :checker, null: false
      t.timestamps
    end
  end
end
