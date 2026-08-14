# frozen_string_literal: true

# Takes a `compilation` local (not an ivar) so index can reuse the exact
# show shape per item — Cerberus chip counts read the same keys either way.
json.compilation do
  json.id compilation.noid
  json.title compilation.title
  json.description compilation.description
  json.depositor compilation.depositor
  json.published compilation.published
  json.included_collections compilation.included_collections
  json.included_works compilation.included_works
  json.excluded_works compilation.excluded_works
  json.edit_users compilation.edit_users
  json.read_groups compilation.read_groups
  json.edit_groups compilation.edit_groups
  json.created_at compilation.created_at.iso8601
  json.updated_at compilation.updated_at.iso8601
end
