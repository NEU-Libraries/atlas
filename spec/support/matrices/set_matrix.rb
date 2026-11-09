# frozen_string_literal: true

require_relative 'flat'

# The Set (Compilation) matrix's table. A Set is an ActiveRecord row with its
# own ACL, not a Resource, so it has no tombstone: its states are its
# visibility. spec/requests/set_matrix_spec.rb sends the requests. See
# docs/testing.md and docs/compilations.md.
module SetMatrix
  TIERS  = %i[guest read_only obo_refused fixity system standard set_reader set_editor owner delegate admin].freeze
  STATES = %i[public_set private_set].freeze
  AXES   = %i[cred_guest cred_assertion cred_obo cred_jwt_read_only cred_system cred_fixity grant_public
              grant_read_group grant_edit_users grant_depositor role_guest role_standard role_delegate role_system
              role_admin].freeze

  READER_GROUP = 'northeastern:drs:matrix:set-readers'

  # The accounts beyond the shared callers. The Set names the reader's group,
  # the editor in edit_users, and the shared :owner as its depositor.
  ACCOUNTS = {
    set_reader: { nuid: '000000071', role: :standard, groups: [READER_GROUP] },
    set_editor: { nuid: '000000072', role: :standard, groups: [] }
  }.freeze

  # Beyond MatrixTree::GUEST_UNTOLD: the Set's own reader group and editor.
  GUEST_UNTOLD = ([READER_GROUP] + ACCOUNTS.values.pluck(:nuid)).freeze

  ADMINS  = %i[admin read_only].freeze
  EDITORS = (%i[set_editor owner] + ADMINS).freeze
  HUMANS  = %i[standard set_reader set_editor owner delegate admin].freeze

  # :system and the fixity checker hold no Set rule at all; everyone else may
  # list their own Sets.
  LISTERS = (HUMANS + %i[guest read_only]).freeze

  READ = lambda do |state, tier|
    state == :public_set ? LISTERS.include?(tier) : (EDITORS + %i[set_reader]).include?(tier)
  end

  MATRIX = {
    'compilations#index'                      => [:list, { allowed: LISTERS }],
    'compilations#show'                       => [:read, { allowed: READ }],
    'compilations#contents'                   => [:read, { allowed: READ }],
    'compilations#create'                     => [:create, { allowed: HUMANS, write: true, ok: 201, json: true,
                                                             params: ->(_, _) { { title: 'Matrix Set' } } }],
    'compilations#update'                     => [:edit, { allowed: EDITORS, write: true, json: true,
                                                           params: ->(_, _) { { title: 'Matrix Set' } } }],
    'compilations#destroy'                    => [:edit, { allowed: EDITORS, write: true, ok: 204, fresh: true }],
    'compilations#add_included_collection'    => [:edit, { allowed: EDITORS, write: true, json: true,
                                                           params: ->(s, _) { { collection_id: s[:collection].noid } } }],
    'compilations#remove_included_collection' => [:edit, { allowed: EDITORS, write: true,
                                                           path: ->(s) { { collection_id: s[:collection].noid } } }],
    'compilations#add_included_work'          => [:edit, { allowed: EDITORS, write: true, json: true,
                                                           params: ->(s, _) { { work_id: s[:work].noid } } }],
    'compilations#remove_included_work'       => [:edit, { allowed: EDITORS, write: true,
                                                           path: ->(s) { { work_id: s[:work].noid } } }],
    'compilations#add_exclusion'              => [:edit, { allowed: EDITORS, write: true, json: true,
                                                           params: ->(s, _) { { work_id: s[:work].noid } } }],
    'compilations#remove_exclusion'           => [:edit, { allowed: EDITORS, write: true,
                                                           path: ->(s) { { work_id: s[:work].noid } } }],
    # Publishing puts a Set into OAI-PMH, so it is admin-only.
    'compilations#publish'                    => [:admin, { allowed: ADMINS, write: true }],
    'compilations#unpublish'                  => [:admin, { allowed: ADMINS, write: true }]
  }.freeze

  UNSCOPED = {}.freeze
end
