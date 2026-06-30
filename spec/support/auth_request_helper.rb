# frozen_string_literal: true

# Default authentication for request/controller specs that don't drive the auth
# matrix themselves. With the Ability layer, guest can't write, so these specs
# need a real authenticated principal.
#
# The default is a Cerberus-SIGNED assertion: a short-lived ES256 JWT
# (iss=cerberus, aud=atlas, sub=admin) verified against a stubbed public keyset —
# the same path Cerberus uses in production. No `User:` header; identity is the
# signed `sub`. Specs that test the auth matrix opt out with `default_auth: false`.
#
# NOTE: principal is the assertion's `sub`, NOT a `User:` header. A spec that
# needs to act as a different NUID must supply its own assertion (or set
# `default_auth: false`); overriding the `User:` header does not switch the
# acting principal on this path.
#
# Per-request headers still win over these defaults (Hash#merge favours caller).

module DefaultAuthHeaders
  mattr_accessor :default_headers, default: nil

  # One test signing keypair for the whole run; its public half is stubbed into
  # credentials.cerberus_signing_keys per example (see ensure_default_admin!).
  SIGNING_KEY = OpenSSL::PKey::EC.generate('prime256v1')
  KID         = 'test-default'
  ADMIN_NUID  = '000000004'

  # A fresh signed assertion for any NUID (1h TTL — longer than any example).
  # Pass obo: to carry a signed acting-as claim (operator = nuid, target = obo).
  def self.assertion_for(nuid, obo: nil)
    now    = Time.now.to_i
    claims = { 'iss' => 'cerberus', 'aud' => 'atlas', 'sub' => nuid.to_s,
               'iat' => now, 'exp' => now + 3600 }
    claims['obo'] = obo.to_s if obo
    JWT.encode(claims, SIGNING_KEY, 'ES256', { kid: KID })
  end

  def self.admin_assertion = assertion_for(ADMIN_NUID)

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
    .to receive(:cerberus_signing_keys)
    .and_return({ DefaultAuthHeaders::KID => DefaultAuthHeaders::SIGNING_KEY.public_to_pem })

  User.find_by(nuid: DefaultAuthHeaders::ADMIN_NUID) ||
    User.create!(email: 'admin@example.invalid', password: SecureRandom.hex(16),
                 nuid: DefaultAuthHeaders::ADMIN_NUID, name: 'User, Admin', role: :admin)
end

# Auth headers for a SPECIFIC principal, for specs that opt out of the default
# (default_auth: false) and switch principals. Stubs the keyset so the assertion
# verifies, then returns a signed-assertion bearer (sub = nuid). Pass nil for the
# guest path (no Authorization header → require_auth's guest fall-through).
def signed_auth_headers(nuid)
  allow(Rails.application.credentials)
    .to receive(:cerberus_signing_keys)
    .and_return({ DefaultAuthHeaders::KID => DefaultAuthHeaders::SIGNING_KEY.public_to_pem })
  return {} if nuid.nil?

  { 'Authorization' => "Bearer #{DefaultAuthHeaders.assertion_for(nuid)}" }
end

RSpec.configure do |config|
  config.before(:each, type: :request) do |example|
    DefaultAuthHeaders.default_headers = nil
    next if example.metadata[:default_auth] == false

    ensure_default_admin!
    DefaultAuthHeaders.default_headers = { 'Authorization' => "Bearer #{DefaultAuthHeaders.admin_assertion}" }
  end

  config.after(:each, type: :request) do
    DefaultAuthHeaders.default_headers = nil
  end

  # type: :controller goes through ActionController::TestCase, not the
  # integration session — different request path, so the prepend above doesn't
  # intercept. Inject the default assertion via the controller's `request` object.
  config.before(:each, type: :controller) do |example|
    next if example.metadata[:default_auth] == false

    ensure_default_admin!
    request.headers['Authorization'] = "Bearer #{DefaultAuthHeaders.admin_assertion}"
  end
end
