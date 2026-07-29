# frozen_string_literal: true

# NB: the AR-tier Compilation carries a thin mirror of this concern's
# store-agnostic ACL slice (Compilation::ACL) rather than including
# this module — this one is welded to Valkyrie attributes and the
# preservation-envelope path. If you change the ACL helpers here, check
# app/models/compilation/acl.rb, and vice versa.
module Permissions
  extend ActiveSupport::Concern

  STAFF_EDIT_GROUP = 'northeastern:drs:repository:staff'
  # Devolved-admin tier gate (Ability#apply_admin_delegate_abilities): the
  # group half of the :privileged-role + group pair that grants scoped
  # admin-adjacent capabilities below the full :admin role's wildcard.
  ADMIN_GROUP      = 'northeastern:drs:repository:admin'

  # The ACL keys an audit `permissions` event records (before/after). The
  # canonical home for the snapshot shape, shared by the controller edit path
  # (Auditable) and the create-time grant emission (the creators). Embargo and
  # the provenance slots (depositor / proxy_uploader) are intentionally
  # excluded — they carry their own ledger / are not part of the rights diff.
  AUDITED_ACL_KEYS = %i[read edit edit_users].freeze

  included do
    attribute :embargo_release_date, Valkyrie::Types::DateTime.optional

    # Provenance fields.
    # depositor       = intellectual owner (the named author/depositor; may
    #                   point at the seeded :anonymous user for batch loads).
    # proxy_uploader  = hands-on-keyboard actor for the most recent
    #                   ownership-affecting write. Common case: equals
    #                   depositor (self-deposit). Librarian-on-behalf case:
    #                   depositor = faculty NUID, proxy_uploader = librarian NUID.
    # Both are single NUID strings — denormalized projections of current
    # state, queried as O(1) Solr field reads (depositor_ssi /
    # proxy_uploader_ssi). The append-only history lives in AuditEvent.
    attribute :depositor,      Valkyrie::Types::String.optional
    attribute :proxy_uploader, Valkyrie::Types::String.optional
  end

  def embargoed?
    # is embargo_release_date
    return false if embargo_release_date.blank?

    # if it's set, has it passed >, < etc.
    embargo_release_date > DateTime.now
  end

  # Need to clone and mutate due to valkyrie array freeze

  def add_read_group(group_name)
    self.read_groups = read_groups.map(&:clone).unshift(group_name).uniq
  end

  def delete_read_group(group_name)
    return unless read_groups.include?(group_name)

    self.read_groups = read_groups.map(&:clone).reject! { |gn| gn == group_name }
  end

  def add_edit_group(group_name)
    self.edit_groups = edit_groups.map(&:clone).unshift(group_name).uniq
  end

  def delete_edit_group(group_name)
    return if group_name == STAFF_EDIT_GROUP
    return unless edit_groups.include?(group_name)

    self.edit_groups = edit_groups.map(&:clone).reject! { |gn| gn == group_name }
  end

  # Envelope shape — see Preservable / preservation_envelope_writer for
  # the on-disk projection. v2 splits depositor from edit_users (v1
  # aliased them); the schema bump is captured in
  # Preservable::ENVELOPE_SCHEMA_VERSION.
  def permissions
    {
      embargo:        embargo_release_date&.to_s,
      depositor:      depositor,
      proxy_uploader: proxy_uploader,
      edit_users:     edit_users,
      read:           read_groups,
      edit:           edit_groups,
      type:           self.class.name
    }
  end

  # The audited slice of the current ACL — the `before`/`after` payload shape
  # for `permissions` audit events. Normalized by the `permissions=` setter
  # (incl. the staff auto-prepend), so two callers comparing it agree on no-ops.
  def audited_acl
    permissions.slice(*AUDITED_ACL_KEYS)
  end

  def permissions=(hsh)
    # Need to allow for copying another Resource's permissions
    # Heritability, and sentinels down the line
    self.embargo_release_date = hsh[:embargo].present? ? DateTime.parse(hsh[:embargo]) : ''

    # Provenance slots are write-once. The metadata PATCH path
    # (CollectionsController#metadata_update et al.) passes only ACL keys
    # through this setter, so a missing :depositor / :proxy_uploader key
    # must NOT nil the existing stamp. Creators copying parent.permissions
    # always include both keys (via the getter above) and so still write
    # through — the parent.permissions-copy-then-stamp invariant is
    # preserved.
    self.depositor      = hsh[:depositor]      if envelope_carries?(hsh, :depositor)
    self.proxy_uploader = hsh[:proxy_uploader] if envelope_carries?(hsh, :proxy_uploader)
    self.edit_users     = Array(hsh[:edit_users])
    self.read_groups    = hsh[:read]

    incoming_edit = Array(hsh[:edit])
    self.edit_groups = if incoming_edit.include?(STAFF_EDIT_GROUP)
                         incoming_edit
                       else
                         incoming_edit.unshift(STAFF_EDIT_GROUP)
                       end
  end

  # Either symbol-keyed (creator-side, from the `permissions` getter) or
  # string-keyed (controller-side, from ActionController::Parameters);
  # the setter accepts both shapes.
  def envelope_carries?(hsh, key)
    hsh.key?(key) || hsh.key?(key.to_s)
  end

  def public?
    # helper method to void spelunking into internals
    return true if read_groups.include?('public')

    false
  end

  def privatize
    delete_read_group('public')
  end

  def publicize
    add_read_group('public')
  end
end
