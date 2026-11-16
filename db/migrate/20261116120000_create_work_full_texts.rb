# frozen_string_literal: true

# A Work's extracted text, kept beside its orm_resources row rather than in it.
# Postgres rewrites a jsonb value whole on every update, so text in the metadata
# made every later save of the Work rewrite megabytes and every read carry them.
# See docs/resource-graph.md.
class CreateWorkFullTexts < ActiveRecord::Migration[8.1]
  def up
    create_table :work_full_texts, id: false do |t|
      t.uuid :work_id, primary_key: true
      t.text :body, null: false
      t.timestamps
    end
    # The cascade is what removes the text when a purge or a wipe deletes the Work.
    add_foreign_key :work_full_texts, :orm_resources, column: :work_id, on_delete: :cascade
    # schema.rb cannot record a column's compression, so a database loaded from
    # it uses the default. That changes the cost of a large value, never its content.
    execute 'ALTER TABLE work_full_texts ALTER COLUMN body SET COMPRESSION lz4'
  end

  def down
    drop_table :work_full_texts
  end
end
