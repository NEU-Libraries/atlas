# frozen_string_literal: true

# The repository-wide read-only window. One row, always present: the operator
# opens the window, reads keep being served, every write is refused, migrations
# run, the operator closes it.
#
# A row rather than an environment variable because a deploy replaces the
# containers — an env var would be reset by the very deploy that set it.
class CreateMaintenanceModes < ActiveRecord::Migration[7.0]
  def change
    create_table :maintenance_modes do |t|
      t.boolean  :read_only, default: false, null: false
      t.string   :source
      t.string   :message
      t.integer  :retry_after, default: 900, null: false
      t.datetime :since
      t.timestamps
    end
  end
end
