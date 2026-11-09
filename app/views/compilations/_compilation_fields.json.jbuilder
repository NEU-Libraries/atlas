# frozen_string_literal: true

# The bare Compilation keys, rendered both wrapped (show) and flat (index
# rows), so Cerberus chip counts read the same keys either way. Takes a
# `compilation` local rather than an ivar so index can pass each item.
json.id compilation.noid
json.title compilation.title
json.description compilation.description
json.depositor GuestRedaction.nuid(@current_user, compilation.depositor)
json.published compilation.published
json.included_collections compilation.included_collections
json.included_works compilation.included_works
json.excluded_works compilation.excluded_works
json.edit_users GuestRedaction.nuids(@current_user, compilation.edit_users)
json.read_groups GuestRedaction.groups(@current_user, compilation.read_groups)
json.edit_groups GuestRedaction.groups(@current_user, compilation.edit_groups)
json.created_at compilation.created_at.iso8601
json.updated_at compilation.updated_at.iso8601
