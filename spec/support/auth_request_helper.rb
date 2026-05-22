# frozen_string_literal: true

# Default authentication for request specs that don't explicitly drive the
# auth matrix themselves. Pre-piece-7 the bulk of request specs relied on
# require_auth's guest fall-through (no Authorization header → guest user)
# because all writes were ungated. With piece 7's Ability layer, guest can
# no longer create/update/destroy resources, so those specs need a real
# authenticated principal.
#
# Default: every request-type spec gets a stubbed cerberus token and the
# admin fixture (NUID 000000004) injected as the acting principal. Specs
# that test require_auth or other auth-matrix concerns can opt out at the
# `describe` level with `default_auth: false`.
#
# Per-request headers (`get '/foo', headers: { 'X' => 'y' }`) still win over
# these defaults — Hash#merge favors the caller-supplied value.

module DefaultAuthHeaders
  # Class-level toggle so before-each can flip it on per example. Process-wide
  # because the integration session is reused; per-example reset clears state.
  mattr_accessor :default_headers, default: nil

  def process(method, path, **kwargs)
    if DefaultAuthHeaders.default_headers
      kwargs[:headers] = DefaultAuthHeaders.default_headers.merge(kwargs[:headers] || {})
    end
    super
  end
end

ActionDispatch::Integration::Session.prepend(DefaultAuthHeaders)

def ensure_default_admin!
  allow(Rails.application.credentials)
    .to receive(:cerberus_token).and_return('test-cerberus-token')

  User.find_by_nuid('000000004') ||
    User.create!(email: 'admin@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000004', name: 'User, Admin', role: :admin)
end

RSpec.configure do |config|
  config.before(:each, type: :request) do |example|
    DefaultAuthHeaders.default_headers = nil
    next if example.metadata[:default_auth] == false

    ensure_default_admin!

    DefaultAuthHeaders.default_headers = {
      'Authorization' => 'Bearer test-cerberus-token',
      'User'          => 'NUID 000000004'
    }
  end

  config.after(:each, type: :request) do
    DefaultAuthHeaders.default_headers = nil
  end

  # type: :controller goes through ActionController::TestCase, not the
  # integration session — different request path, so the prepend above
  # doesn't intercept. Inject admin auth via the controller's `request`
  # object instead. Specs that override request.headers (e.g. to use a
  # specific NUID) overwrite the default per-key.
  config.before(:each, type: :controller) do |example|
    next if example.metadata[:default_auth] == false

    ensure_default_admin!

    request.headers['Authorization'] = 'Bearer test-cerberus-token'
    request.headers['User']          = 'NUID 000000004'
  end
end
