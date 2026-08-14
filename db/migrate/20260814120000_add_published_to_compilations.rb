# frozen_string_literal: true

# The OAI-PMH set flag. A published Compilation becomes an OAI set that any
# harvester can list and walk (Digital Commonwealth is the first consumer), so
# it defaults to false — a Set stays personal curation until an admin says
# otherwise. Indexed because ListSets and every record header consult it.
class AddPublishedToCompilations < ActiveRecord::Migration[7.0]
  def change
    add_column :compilations, :published, :boolean, default: false, null: false
    add_index  :compilations, :published
  end
end
