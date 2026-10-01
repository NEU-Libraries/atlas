# frozen_string_literal: true

# Minimal-disclosure directory entry: a directory, not a profile endpoint —
# no email, no role, no groups. display_name is the public Person name, so it
# discloses nothing /people/:id does not; the user must come from
# User.directory_entries, which selects it.
json.nuid user.nuid
json.name user.name
json.display_name user.person_display_name
