# frozen_string_literal: true

# The fixture-tree vocabulary every resource matrix shares: its states, the
# subjects each state withholds and the markers planted in them. It loads
# without RSpec, so bin/acl-coverage can read it. See docs/testing.md.
module MatrixTree
  # The states every matrix shares: a resource live, a Work narrowed to its
  # editors, and a tombstone on each type that can carry one.
  STATES = %i[live private work_tombstoned file_set_tombstoned collection_tombstoned community_tombstoned].freeze
  OPERATORS = %i[delegate admin].freeze

  # The subject each state tombstones directly.
  TOMBSTONED = {
    work_tombstoned:       :work,
    file_set_tombstoned:   :file_set,
    collection_tombstoned: :empty_collection,
    community_tombstoned:  :sub_community
  }.freeze

  # The subjects each state withholds. A leaf is withheld by its own tombstone
  # and by its Work's; the Delegate hangs off the Work.
  WITHHELD = {
    live:                  [],
    private:               [],
    work_tombstoned:       %i[work delegate file_set blob],
    file_set_tombstoned:   %i[file_set blob],
    collection_tombstoned: %i[empty_collection],
    community_tombstoned:  %i[sub_community]
  }.freeze

  # The private state narrows the Work's ACL, which its leaves read through.
  PRIVATE_SUBJECTS = %i[work delegate file_set blob].freeze

  # A marker string planted in each subject. Below the operator tiers, no
  # response from any read route may carry the marker of a withheld subject.
  MARKERS = {
    work:             'zqworkmarker',
    delegate:         'zqdelegatemarker',
    blob:             'zqfilemarker',
    empty_collection: 'zqcollectionmarker',
    sub_community:    'zqcommunitymarker'
  }.freeze
end
