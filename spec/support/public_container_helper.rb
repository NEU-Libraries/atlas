# frozen_string_literal: true

# Fixture-tree helper for specs that make a child resource public.
#
# Root Communities are born private — they have no parent to inherit an ACL
# from — and PermissionsWriteGuard refuses a child more visible than its
# container, so a spec that PATCHes `read: ['public']` onto a Work needs a
# publicly readable chain above it. Production trees are built this way
# (Cerberus's seed publicizes the root Community first, then descends), so
# using this in place of a bare CommunityCreator.call keeps the fixture shaped
# like the real thing.
def public_community!(**kwargs)
  community = CommunityCreator.call(**kwargs)
  community.publicize
  Atlas.persister.save(resource: community)
end
