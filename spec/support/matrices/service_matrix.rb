# frozen_string_literal: true

require_relative 'flat'

# The service matrix's table: the operator endpoints, the backend sweeps and
# the public endpoints, none keyed on a resource in the tree.
# spec/requests/service_matrix_spec.rb sends the requests. See
# docs/testing.md.
module ServiceMatrix
  TIERS  = %i[guest read_only obo_refused fixity system standard delegate admin].freeze
  STATES = %i[live maintenance].freeze
  AXES   = %i[cred_guest cred_assertion cred_obo cred_jwt_read_only cred_system cred_fixity role_guest
              role_standard role_delegate role_system role_admin state_live state_maintenance].freeze

  ACCOUNTS = {}.freeze

  ADMINS    = %i[admin read_only].freeze
  OPERATORS = (%i[delegate] + ADMINS).freeze
  HUMANS    = (%i[standard] + OPERATORS).freeze
  EVERYONE  = (%i[guest system] + HUMANS).freeze

  MATRIX = {
    'communities#index'        => [:admin, { allowed: ADMINS }],
    'collections#index'        => [:admin, { allowed: ADMINS }],
    'resources#preview'        => [:human, { allowed: HUMANS, params: ->(_, _) { { binary: WriteMatrix.upload('work-mods.xml', 'application/xml') } } }],
    'blobs#find_many_versions' => [:operator, { allowed: OPERATORS, json: true, params: ->(_, _) { { ids: [] } } }],
    # The checker's own reads and writes. The due list is not on the read-only
    # allowlist, so a read-only token and the maintenance window refuse it.
    'fixity_checks#due'        => [:fixity, { allowed: %i[fixity admin], write: true }],
    'fixity_checks#create'     => [:fixity, { allowed: %i[fixity admin], write: true, json: true, ok: [200, 201],
                                              params: ->(s, _) { s[:check] } }],
    'audit_events#create'      => [:operator, { allowed: %i[delegate admin], write: true, json: true, ok: 201,
                                                params: ->(_, _) { { action: 'impersonation_started', actor_nuid: '000000004', on_behalf_of_nuid: '000000069', mode: 'acting_as' } } }],
    'embargoes#release'        => [:backend, { allowed: %i[system admin], write: true }],
    'metrics#latency'          => [:backend, { allowed: %i[system] + ADMINS }],
    'maintenance#show'         => [:everyone, { allowed: EVERYONE }],
    # The window must stay closable while it is open. The body re-sends the
    # state's own flag, so a permitted call leaves the window as it found it.
    'maintenance#update'       => [:backend, { allowed: %i[system admin], write: true, maintenance_exempt: true, json: true,
                                               params: ->(_, state) { { read_only: state == :maintenance } } }],
    # Sent with the environment guard closed, as production has it: nobody
    # resets, and the answer is a 404 rather than an error.
    'maintenance#reset'        => [:public, { no_auth: true, ok: 404 }],
    'health#show'              => [:public, { no_auth: true }],
    'docs#show'                => [:public, { no_auth: true }],
    'oai#index'                => [:public, { no_auth: true, params: ->(_, _) { { verb: 'Identify' } } }],
    'oai#index@post'           => [:public, { no_auth: true, verb: 'POST', params: ->(_, _) { { verb: 'Identify' } } }]
  }.freeze

  UNSCOPED = {}.freeze
end
