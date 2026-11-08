# frozen_string_literal: true

require_relative 'flat'

# The People matrix's table. A Person is public and curated by :system and the
# admin; a person may edit only their own profile.
# spec/requests/people_matrix_spec.rb sends the requests. See docs/testing.md
# and docs/people.md.
module PeopleMatrix
  TIERS  = %i[guest read_only obo_refused fixity system standard self delegate admin].freeze
  STATES = %i[live maintenance].freeze
  AXES   = %i[cred_guest cred_assertion cred_obo cred_jwt_read_only cred_system cred_fixity grant_public
              role_guest role_standard role_delegate role_system role_admin state_live state_maintenance].freeze

  # The subject Person's own account.
  ACCOUNTS = { self: { nuid: '000000073', role: :standard, groups: [] } }.freeze

  READERS   = %i[guest read_only system standard self delegate admin].freeze
  CURATORS  = %i[system admin].freeze

  MATRIX = {
    'people#index'              => [:read, { allowed: READERS }],
    # A name fragment matches NUIDs and account emails, so searching is an
    # enumeration tool and admin-only.
    'people#index@search'       => [:admin, { allowed: %i[admin read_only], params: ->(_, _) { { q: 'Matrix' } } }],
    'people#show'               => [:read, { allowed: READERS }],
    'people#create'             => [:curate, { allowed: CURATORS, write: true, ok: 201, json: true,
                                               params: ->(_, _) { { nuid: format('0099%05d', rand(100_000)), display_name: 'Matrix, New' } } }],
    'people#update'             => [:own, { allowed: %i[self system admin], write: true, json: true,
                                            params: ->(_, _) { { display_name: 'Matrix, Self' } } }],
    'people#add_affiliation'    => [:curate, { allowed: CURATORS, write: true, json: true,
                                               params: ->(s, _) { { community_id: s[:community].noid } } }],
    'people#remove_affiliation' => [:curate, { allowed: CURATORS, write: true,
                                               path: ->(s) { { community_id: s[:community].noid } } }]
  }.freeze

  UNSCOPED = {}.freeze
end
