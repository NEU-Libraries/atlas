# frozen_string_literal: true

# The MODS and METS access copies are looked up exclusively by valkyrie_id
# (which holds the resource's NOID — see Modsable#mods), and neither table
# carried an index on it, so every lookup was a sequential scan. That is the
# other half of batching those reads: one scan per page beats one per row, but
# an index makes it a lookup either way.
#
# Not unique: the column is nullable and the uniqueness of one row per resource
# is enforced by find_or_create_by, not by the schema. Making it unique here
# would fail the migration on any repository that already has a duplicate.
class IndexMetadataAccessCopiesByValkyrieId < ActiveRecord::Migration[7.0]
  def change
    add_index :metadata_mods, :valkyrie_id
    add_index :metadata_mets, :valkyrie_id
  end
end
