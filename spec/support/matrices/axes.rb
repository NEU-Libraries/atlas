# frozen_string_literal: true

# Every way a caller can be granted or refused access, by axis. A matrix
# declares in its AXES which of these its tiers and states exercise, and
# bin/acl-coverage reports the share the matrices reach between them. Add a
# value here when Atlas gains a credential, a grant source, a role or a state.
# See docs/testing.md.
module ACLAxes
  AXES = {
    credentials:   {
      cred_guest:         'No token (guest)',
      cred_assertion:     'Signed Cerberus assertion',
      cred_obo:           'Assertion with a signed obo claim',
      cred_jwt:           'Personal JWT, read-write',
      cred_jwt_read_only: 'Personal JWT, read-only',
      cred_system:        'System token',
      cred_fixity:        'Fixity token'
    },
    grant_sources: {
      grant_public:      'Public read group',
      grant_read_group:  'Read-group membership',
      grant_edit_users:  'edit_users on the Work',
      grant_edit_groups: 'edit_groups on the Work',
      grant_depositor:   'Depositor ownership alone',
      grant_container:   'Edit grant on a container'
    },
    roles:         {
      role_guest:      'guest',
      role_standard:   'standard',
      role_loader:     'loader',
      role_privileged: 'privileged without the admin group',
      role_delegate:   'delegated admin',
      role_staff:      'repository:staff member',
      role_system:     'system',
      role_admin:      'admin'
    },
    states:        {
      state_live:            'live',
      state_private:         'private Work',
      state_work_tomb:       'Work tombstoned',
      state_file_set_tomb:   'FileSet tombstoned',
      state_collection_tomb: 'Collection tombstoned',
      state_community_tomb:  'Community tombstoned',
      state_embargoed:       'embargoed',
      state_tier_reserved:   'tier reserved',
      state_maintenance:     'maintenance window',
      state_purged:          'purged identifier',
      state_unattached:      'unattached leaf'
    }
  }.freeze

  def self.ids = AXES.values.flat_map(&:keys)
end
