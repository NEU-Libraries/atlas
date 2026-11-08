# frozen_string_literal: true

# The fixture-tree vocabulary every resource matrix shares: its states, the
# subjects each state withholds, the markers planted in them, and the callers
# with what each one holds. It loads without RSpec, so bin/acl-coverage can
# read it. See docs/testing.md.
module MatrixTree
  # The states every matrix shares: a resource live, a Work narrowed to its
  # editors, and a tombstone on each type that can carry one.
  STATES = %i[live private work_tombstoned file_set_tombstoned collection_tombstoned community_tombstoned].freeze

  # The subject each state tombstones directly.
  TOMBSTONED = {
    work_tombstoned:       :work,
    file_set_tombstoned:   :file_set,
    collection_tombstoned: :empty_collection,
    community_tombstoned:  :sub_community
  }.freeze

  # The subjects each state withholds. A leaf is withheld by its own tombstone
  # and by its Work's; the Delegates hang off the Work.
  WITHHELD = {
    live:                  [],
    private:               [],
    work_tombstoned:       %i[work delegate gated_delegate file_set blob],
    file_set_tombstoned:   %i[file_set blob],
    collection_tombstoned: %i[empty_collection],
    community_tombstoned:  %i[sub_community]
  }.freeze

  # The private state narrows the Work's ACL, which its leaves read through.
  PRIVATE_SUBJECTS = %i[work delegate gated_delegate file_set blob].freeze

  # A marker string planted in each subject. Below the operator tiers, no
  # response from any read route may carry the marker of a withheld subject.
  MARKERS = {
    work:             'zqworkmarker',
    delegate:         'zqdelegatemarker',
    gated_delegate:   'zqgatedmarker',
    blob:             'zqfilemarker',
    empty_collection: 'zqcollectionmarker',
    sub_community:    'zqcommunitymarker'
  }.freeze

  # Groups no real account holds: one the group_read state reads through, one
  # the Work's edit_groups name, and one the tier_gated state reserves to.
  READER_GROUP   = 'northeastern:drs:matrix:readers'
  EDITOR_GROUP   = 'northeastern:drs:matrix:editors'
  RESERVED_GROUP = 'northeastern:drs:matrix:reserved'
  STAFF_GROUP    = 'northeastern:drs:repository:staff'
  ADMIN_GROUP    = 'northeastern:drs:repository:admin'

  # The human callers' accounts. The others are built from these: :jwt_editor
  # is the editor on a personal token, :obo_refused the standard user carrying
  # an acting-as claim, :acting_admin the admin acting as the owner.
  ACCOUNTS = {
    standard:     { nuid: '000000063', role: :standard, groups: [] },
    loader:       { nuid: '000000064', role: :loader, groups: [] },
    privileged:   { nuid: '000000065', role: :privileged, groups: [] },
    group_reader: { nuid: '000000066', role: :standard, groups: [READER_GROUP, RESERVED_GROUP] },
    curator:      { nuid: '000000067', role: :standard, groups: [] },
    editor:       { nuid: '000000061', role: :standard, groups: [] },
    group_editor: { nuid: '000000068', role: :standard, groups: [EDITOR_GROUP] },
    owner:        { nuid: '000000069', role: :standard, groups: [] },
    staff:        { nuid: '000000070', role: :standard, groups: [STAFF_GROUP] },
    delegate:     { nuid: '000000062', role: :privileged, groups: [ADMIN_GROUP] }
  }.freeze

  # What each caller holds in the fixture world. Every expected cell is
  # derived from these sets, so a caller's meaning is stated once.
  #
  # The editor holds edit_users on the Work, the group editor edit_groups, the
  # owner is its depositor and nothing else, and staff hold the edit group
  # Atlas prepends to every resource. The curator holds edit_users on the
  # containers and not on the Work.
  WORK_EDITORS      = %i[editor group_editor owner jwt_editor staff].freeze
  CONTAINER_EDITORS = %i[curator staff].freeze
  ADMINS            = %i[admin acting_admin].freeze
  OPERATORS         = (%i[delegate] + ADMINS).freeze
  EMBARGO_BYPASS    = (%i[staff] + ADMINS).freeze
  TIER_AUDIENCE     = (%i[group_reader] + WORK_EDITORS + ADMINS).freeze
  # Refused before any gate: an acting-as claim from a non-admin, and the
  # fixity checker, whose ability holds the fixity endpoints and nothing else.
  REFUSED           = %i[obo_refused fixity].freeze

  def self.work_reader?(tier) = WORK_EDITORS.include?(tier) || ADMINS.include?(tier)
end
