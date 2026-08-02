# frozen_string_literal: true

class Compilation
  # ACL vocabulary for the AR-tier Compilation — a thin mirror of the
  # store-agnostic slice of the resource-side Permissions concern
  # (app/models/concerns/permissions.rb). Mirror, don't extract: Permissions
  # is included in preservation-envelope paths (Preservable projects its
  # `permissions` hash to disk) and refactoring it for one AR consumer is
  # risk without payoff. If you change the ACL helpers there, check here —
  # and vice versa.
  #
  # Named ACL (not Compilation::Permissions): a nested Permissions constant
  # would shadow the top-level concern inside this namespace, making the
  # `::Permissions` cross-references here a constant-lookup trap.
  #
  # Deliberate omissions vs the resource concern:
  #  - no embargo, no proxy_uploader — Compilations carry neither.
  #  - no STAFF_EDIT_GROUP auto-prepend (and no delete guard for it): a
  #    *personal* Set should not be staff-editable by default. Owner +
  #    explicit grants + admin wildcard only.
  #  - depositor is write-once at create (stamped by the controller from the
  #    authenticated NUID); the `permissions=` setter never touches it.
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

    # The grant keys of the resource concern's audited slice, so `permissions`
    # audit rows for Compilations read like resource rows. Local rather than
    # borrowed: that constant also carries :embargo, which Compilations don't
    # have, and slicing a key that is never present is a claim this mirror
    # can't honour.
    AUDITED_KEYS = %i[read edit edit_users].freeze

    def audited_acl
      permissions.slice(*AUDITED_KEYS)
    end

    # ACL slice only — replaces all three grant lists. Accepts symbol- or
    # string-keyed hashes (ActionController::Parameters arrives string-keyed).
    def permissions=(hsh)
      hsh = hsh.to_h.symbolize_keys
      self.edit_users  = Array(hsh[:edit_users])
      self.read_groups = Array(hsh[:read])
      self.edit_groups = Array(hsh[:edit]) # no staff auto-prepend (F2)
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
