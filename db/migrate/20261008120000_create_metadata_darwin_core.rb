# frozen_string_literal: true

# The Darwin Core access copy, shaped like metadata_mets and indexed the same
# way: every read looks a row up by valkyrie_id, which holds the Work's NOID.
class CreateMetadataDarwinCore < ActiveRecord::Migration[7.0]
  def change
    create_table :metadata_darwin_core do |t|
      t.jsonb :json_attributes
      t.string :valkyrie_id
      t.timestamps
    end
    add_index :metadata_darwin_core, :valkyrie_id
  end
end
