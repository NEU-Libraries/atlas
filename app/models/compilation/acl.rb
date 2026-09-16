# frozen_string_literal: true

class Compilation
  # ACL vocabulary for the AR-tier Compilation: a deliberate mirror of the
  # store-agnostic slice of app/models/concerns/permissions.rb, not an
  # include. Change an ACL helper there and check here, and vice versa. See
  # docs/authorization.md for why it mirrors and what it omits.
  #
  # Named ACL, not Compilation::Permissions: a nested Permissions constant
  # would shadow the top-level concern inside this namespace and turn every
  # `::Permissions` cross-reference into a constant-lookup trap.
  module ACL
    def add_read_group(group_name)
      self.read_groups = ([group_name] + read_groups).uniq
    end

    def delete_read_group(group_name)
      self.read_groups = read_groups - [group_name]
    end

    def add_edit_group(group_name)
      self.edit_groups = ([group_name] + edit_groups).uniq
    end

    def delete_edit_group(group_name)
      self.edit_groups = edit_groups - [group_name]
    end

    def permissions
      {
        depositor:  depositor,
        edit_users: edit_users,
        read:       read_groups,
        edit:       edit_groups,
        type:       self.class.name
      }
    end

    # Local rather than borrowed from AUDITED_ACL_KEYS: that constant also
    # carries :embargo, and slicing a key that is never present is a claim
    # this mirror can't honour.
    AUDITED_KEYS = %i[read edit edit_users].freeze

    def audited_acl
      permissions.slice(*AUDITED_KEYS)
    end

    # Replaces all three grant lists. Accepts symbol- or string-keyed hashes.
    def permissions=(hsh)
      hsh = hsh.to_h.symbolize_keys
      self.edit_users  = Array(hsh[:edit_users])
      self.read_groups = Array(hsh[:read])
      self.edit_groups = Array(hsh[:edit]) # no staff auto-prepend, deliberately
    end

    def public?
      read_groups.include?('public')
    end

    def privatize
      delete_read_group('public')
    end

    def publicize
      add_read_group('public')
    end
  end
end
