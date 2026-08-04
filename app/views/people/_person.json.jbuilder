json.person do
  json.id person.noid
  json.valkyrie_id person.id.to_s
  json.nuid person.nuid
  json.display_name person.display_name
  json.bio person.bio
  json.orcid person.orcid
  json.affiliated_community_ids person.affiliated_community_noids
  # NOID of the Person's personal-root Collection (the publish conduit's
  # structural parent). Stored as a NOID, so emitted directly — no resolve.
  json.personal_root_id person.personal_root_id
end
