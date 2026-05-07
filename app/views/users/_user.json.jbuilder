json.user do
  json.id     user.id
  json.nuid   user.nuid
  json.name   user.name
  json.email  user.email
  json.role   user.role
  json.groups user.groups
end
