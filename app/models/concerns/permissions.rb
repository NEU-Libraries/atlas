# frozen_string_literal: true

# The ACL envelope on a Valkyrie resource. See docs/authorization.md for the
# envelope shape, the provenance rules and the staff auto-prepend.
#
# Compilation::ACL (app/models/compilation/acl.rb) is a deliberate mirror of
# this concern's store-agnostic slice, not an include. Change an ACL helper
# here and check there, and vice versa.
module Permissions
  extend ActiveSupport::Concern

  STAFF_EDIT_GROUP = 'northeastern:drs:repository:staff'
  # The group half of the devolved-admin pair; User#admin_delegate? also
  # requires the :privileged role.
  ADMIN_GROUP      = 'northeastern:drs:repository:admin'

  # The before/after payload shape of a `permissions` audit event. Embargo is
  # in the diff because nothing else records who moved it; the provenance
  # slots stay out, being write-once rather than part of a rights diff.
  AUDITED_ACL_KEYS = %i[read edit edit_users embargo].freeze

  included do
    attribute :embargo_release_date, Valkyrie::Types::DateTime.optional

    # Single NUID strings, denormalized so they read as O(1) Solr fields
    # (depositor_ssi / proxy_uploader_ssi). The append-only history lives in
    # AuditEvent.
    attribute :depositor,      Valkyrie::Types::String.optional
    attribute :proxy_uploader, Valkyrie::Types::String.optional
  end

  def embargoed?
    return false if embargo_release_date.blank?

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

  # Preservable projects this hash to disk, so the schema bump for any change
  # here belongs in Preservable::ENVELOPE_SCHEMA_VERSION.
  #
  # `presence` on the embargo collapses the two shapes "no embargo" can take:
  # the setter normalizes a blank date to '', but a resource never put through
  # the setter (a root Community) still holds nil. Without it, the audited
  # slice reads that nil -> '' step as a change and emits a `permissions`
  # event in which nothing moved.
  def permissions
    {
      embargo:        embargo_release_date.presence&.to_s,
      depositor:      depositor,
      proxy_uploader: proxy_uploader,
      edit_users:     edit_users,
      read:           read_groups,
      edit:           edit_groups,
      type:           self.class.name
    }
  end

  # Normalized by the setter below (including the staff auto-prepend), so two
  # callers comparing this agree on no-ops.
  def audited_acl
    permissions.slice(*AUDITED_ACL_KEYS)
  end

  # EVERY key merges: a key the envelope does not carry keeps its stored value.
  # That is what makes the ACL PATCH's verb true, and it is what stops a
  # payload carrying one slot from blanking the others -- a caller sending only
  # `read` used to clear the embargo release date with it. To clear a key, send
  # it explicitly empty.
  #
  # Creators copying parent.permissions carry every key, so heritability still
  # writes through unchanged.
  def permissions=(hsh)
    self.embargo_release_date = incoming_embargo(hsh)        if envelope_carries?(hsh, :embargo)
    self.depositor            = hsh[:depositor]              if envelope_carries?(hsh, :depositor)
    self.proxy_uploader       = hsh[:proxy_uploader]          if envelope_carries?(hsh, :proxy_uploader)
    self.edit_users           = Array(hsh[:edit_users])       if envelope_carries?(hsh, :edit_users)
    self.read_groups          = hsh[:read]                    if envelope_carries?(hsh, :read)
    self.edit_groups          = with_staff_edit_group(hsh[:edit]) if envelope_carries?(hsh, :edit)
  end

  # The setter normalizes "no embargo" to '' rather than nil, so #permissions
  # can collapse the two shapes it would otherwise read back.
  def incoming_embargo(hsh)
    hsh[:embargo].present? ? DateTime.parse(hsh[:embargo]) : ''
  end

  # Staff keep edit rights on everything, so the group is prepended rather
  # than trusted to arrive. Callers comparing two ACLs for a no-op depend on
  # this normalization happening before the comparison.
  def with_staff_edit_group(incoming)
    groups = Array(incoming)
    return groups if groups.include?(STAFF_EDIT_GROUP)

    groups.unshift(STAFF_EDIT_GROUP)
  end

  # Symbol-keyed from the creator side, string-keyed from
  # ActionController::Parameters; the setter accepts both.
  def envelope_carries?(hsh, key)
    hsh.key?(key) || hsh.key?(key.to_s)
  end

  def public?
    return true if read_groups.include?('public')

    false
  end

  # The resource whose ACL decides whether this one may be read. Works and
  # containers answer for themselves; FileSet, Blob and Delegate override this
  # to walk upward, because their own ACL is a stale copy taken at creation and
  # nothing rewrites it afterwards.
  #
  # nil means no authority could be resolved, and callers must read that as
  # "deny". An unattached leaf has nobody to answer for it.
  def read_authority
    self
  end

  def privatize
    delete_read_group('public')
  end

  def publicize
    add_read_group('public')
  end
end
