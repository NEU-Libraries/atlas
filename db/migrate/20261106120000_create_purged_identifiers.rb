# frozen_string_literal: true

# One row per NOID a purge removed: the record that the ID existed once the
# row, the Solr document and the OCFL object are gone. A purged ID's read
# answers 410 from it, and the minter never reissues it. See
# docs/resource-graph.md.
class CreatePurgedIdentifiers < ActiveRecord::Migration[8.1]
  def change
    create_table :purged_identifiers, id: false do |t|
      t.string :noid, null: false, primary_key: true
      t.string :resource_type, null: false
      t.datetime :purged_at, null: false
      t.string :purged_by
    end
  end
end
