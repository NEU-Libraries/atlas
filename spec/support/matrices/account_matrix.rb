# frozen_string_literal: true

require_relative 'flat'

# The account matrix's table: the user directory, a person's accounts, and the
# token endpoints Cerberus uses after SSO. spec/requests/account_matrix_spec.rb
# sends the requests. See docs/testing.md and docs/authentication.md.
module AccountMatrix
  TIERS  = %i[guest read_only obo_refused fixity system standard other delegate admin].freeze
  STATES = %i[live maintenance].freeze
  AXES   = %i[cred_guest cred_assertion cred_obo cred_jwt_read_only cred_system cred_fixity role_guest
              role_standard role_delegate role_system role_admin state_live state_maintenance].freeze

  # :standard is the account the rows name; :other is a second human who must
  # not reach it. The provisioning rows act on a third account no tier uses.
  ACCOUNTS = { other: { nuid: '000000074', role: :standard, groups: [] } }.freeze
  TARGET   = { nuid: '000000075', email: 'target-matrix@example.invalid' }.freeze

  DIRECTORY = %i[read_only system standard other delegate admin].freeze
  OWNERS    = %i[read_only system standard admin].freeze
  BACKEND   = %i[system admin].freeze

  MATRIX = {
    'users#index'             => [:directory, { allowed: DIRECTORY }],
    'users#show'              => [:directory, { allowed: DIRECTORY, path: ->(s) { { nuid: s[:standard].nuid } } }],
    'users#accounts'          => [:own, { allowed: OWNERS, path: ->(s) { { nuid: s[:standard].nuid } } }],
    'users#preferred_account' => [:own, { allowed: OWNERS, write: true, json: true,
                                          path:   ->(s) { { nuid: s[:standard].nuid } },
                                          params: ->(s, _) { { email: s[:standard].email } } }],
    'users#update'            => [:provision, { allowed: BACKEND, write: true, json: true,
                                                path:   ->(_) { { nuid: TARGET[:nuid] } },
                                                params: ->(_, _) { { groups: [] } } }],
    'users#update_by_email'   => [:provision, { allowed: BACKEND, write: true, json: true,
                                                path:   ->(_) { { email: TARGET[:email] } },
                                                params: ->(_, _) { { nuid: TARGET[:nuid], name: 'Target, Matrix' } } }],
    'users/tokens#show'       => [:self, { allowed: %i[guest] + DIRECTORY }],
    'users/tokens#nuid'       => [:mint, { allowed: BACKEND, write: true, json: true,
                                           params: ->(_, _) { { nuid: TARGET[:nuid] } } }],
    'users/tokens#revoke'     => [:mint, { allowed: BACKEND, write: true, json: true, ok: 204,
                                           params: ->(_, _) { { nuid: TARGET[:nuid] } } }]
  }.freeze

  UNSCOPED = {}.freeze
end
