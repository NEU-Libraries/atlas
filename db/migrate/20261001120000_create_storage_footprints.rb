# frozen_string_literal: true

# One row per OCFL object: the bytes it holds on disk, kept by the storage
# adapter as each version is written. Derived and disposable, like the rest of
# Postgres: `rake storage:footprints:rebuild` recomputes it from disk. See
# docs/binaries.md.
#
# Keyed by the object key (the resource NOID), not by a foreign key, because
# the adapter writes it and knows only the key.
class CreateStorageFootprints < ActiveRecord::Migration[8.1]
  def change
    create_table :storage_footprints, id: false do |t|
      t.string :object_key, null: false, primary_key: true
      t.bigint :bytes, null: false, default: 0
      t.timestamps
    end
  end
end
