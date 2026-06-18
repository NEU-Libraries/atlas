json.person do
  json.id person.noid
  json.valkyrie_id person.id.to_s
  json.nuid person.nuid
  json.display_name person.display_name
  json.bio person.bio
  json.orcid person.orcid
  json.title person.title
  json.affiliated_community_ids person.affiliated_community_noids
end
