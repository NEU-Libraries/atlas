# frozen_string_literal: true

# Every account sharing a NUID (a person's staff/student logins), oldest first.
# Unlike the minimal directory entry this discloses each account's email,
# affiliation label, role, stored group set, and which one is preferred — the
# data the login "you have more than one account" check and the My DRS accounts
# panel (switch / set-preferred / group diff) render from.
json.nuid @nuid
json.accounts @accounts do |account|
  json.email       account.email
  json.name        account.name
  json.affiliation account.affiliation
  json.role        account.role
  json.groups      account.groups
  json.preferred   account.preferred
end
