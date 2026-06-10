# frozen_string_literal: true

# JSON projection of the Work-level structural (METS) metadata — the
# physical structMap's page order surfaces under mets.pages. Mirrors
# file_sets/mets.json.jbuilder.
json.work do
  json.id @work.noid
  json.mets @work.mets.json_attributes
end
