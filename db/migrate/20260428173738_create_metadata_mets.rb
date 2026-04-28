# frozen_string_literal: true

class CreateMetadataMETS < ActiveRecord::Migration[7.0]
  def change
    create_table :metadata_mets do |t|
      t.jsonb :json_attributes
      t.string :valkyrie_id
      t.timestamps
    end
  end
end
