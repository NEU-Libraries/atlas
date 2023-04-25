class AddNuidToUsers < ActiveRecord::Migration[7.0]
  def change
    add_column :users, :nuid, :string
  end
end
