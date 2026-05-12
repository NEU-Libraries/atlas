# frozen_string_literal: true

class CreateIdempotencyKeys < ActiveRecord::Migration[7.0]
  def change
    create_table :idempotency_keys do |t|
      t.references :user, null: false, foreign_key: true
      t.string :key,           null: false
      t.string :resource_type, null: false
      t.string :resource_noid, null: false
      t.timestamps
    end

    add_index :idempotency_keys, %i[user_id key], unique: true
  end
end
