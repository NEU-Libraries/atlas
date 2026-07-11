# frozen_string_literal: true

json.user do
  json.id          user.id
  json.nuid        user.nuid
  json.name        user.name
  json.email       user.email
  json.role        user.role
  json.groups      user.groups
  json.affiliation user.affiliation
  json.preferred   user.preferred
end
