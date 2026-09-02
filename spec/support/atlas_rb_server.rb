# frozen_string_literal: true

# Tag-driven harness for integration specs that drive Atlas through the
# atlas_rb gem. Boots a real Puma server backed by the Rails app and points
# atlas_rb's ENV-driven Faraday connection at it.
#
# Usage:
#
#     RSpec.describe 'Communities', :atlas_rb_server do
#       it 'round-trips' do
#         AtlasRb::Community.create(parent.noid, nuid: '000000004')
#       end
#     end
#
# The server boots lazily on the first tagged example and is reused for the
# rest of the suite. Valkyrie state is wiped after each tagged example —
# transactional fixtures don't apply here, since the test thread and the
# server thread hold different AR connections.
#
# Auth context: the harness drives the gem's **relay-signing** path — it
# configures a test signing key on
# AtlasRb.config and stubs the matching public key into Atlas's
# credentials.cerberus_signing_keys. So a spec's `nuid:` is signed into an
# assertion (sub = that nuid) the live server verifies. `on_behalf_of:` rides as
# a signed `obo` claim. (BYO-JWT specs that set ENV['ATLAS_JWT'] still win over
# signing, per the gem's precedence.) Config is reset after each example.

require 'capybara'
require 'atlas_rb'
require 'openssl'
require 'jwt'

ATLAS_RB_SERVER_ADMIN_NUID = '000000004'

module AtlasRbServer
  class << self
    def boot
      @boot ||= begin
        Capybara.server = :puma, { Silent: true }
        Capybara::Server.new(Rails.application).boot.tap do |server|
          ENV['ATLAS_URL'] = "http://#{server.host}:#{server.port}"
        end
      end
    end
  end
end

RSpec.configure do |config|
  config.before(:each, :atlas_rb_server) do
    AtlasRbServer.boot

    # Share ONE test signing identity with DefaultAuthHeaders. Integration specs
    # are type: :request too, so both this hook and DefaultAuthHeaders' run and
    # both stub cerberus_signing_keys — using the same key/kid keeps them from
    # clobbering each other (whichever wins, it matches what the gem signs with).
    AtlasRb.config.assertion_signing_key = DefaultAuthHeaders::SIGNING_KEY
    AtlasRb.config.assertion_signing_kid = DefaultAuthHeaders::KID
    allow(Rails.application.credentials)
      .to receive(:cerberus_signing_keys)
      .and_return({ DefaultAuthHeaders::KID => DefaultAuthHeaders::SIGNING_KEY.public_to_pem })

    User.find_by(nuid: ATLAS_RB_SERVER_ADMIN_NUID) ||
      User.create!(email: 'admin-atlas-rb@example.invalid', password: SecureRandom.hex(16),
                   nuid: ATLAS_RB_SERVER_ADMIN_NUID, name: 'User, Admin', role: :admin)
  end

  config.after(:each, :atlas_rb_server) do
    AtlasRb.config.assertion_signing_key = nil
    AtlasRb.config.assertion_signing_kid = nil
    # atlas_rb pools its sockets, so a connection opened by one example would
    # otherwise stay open into the next — cross-example coupling that is much
    # cheaper to prevent here than to diagnose later from a flaky failure.
    AtlasRb::Transport.reset_connections!
    Atlas.persister.wipe!
  end
end
