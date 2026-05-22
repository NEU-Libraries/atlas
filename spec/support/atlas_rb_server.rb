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
# Auth context: every example in spec/integration/ now threads
# `nuid: admin_nuid` explicitly via atlas_rb 0.0.101's uniform kwarg
# coverage. The harness seeds the admin fixture and stubs the cerberus
# token so those `nuid:` values land on a wire that Atlas's tightened
# require_auth + Ability layer will accept.

require 'capybara'
require 'atlas_rb'

ATLAS_RB_SERVER_TOKEN = 'test-cerberus-token'
ATLAS_RB_SERVER_ADMIN_NUID = '000000004'

module AtlasRbServer
  class << self
    def boot
      @server ||= begin
        Capybara.server = :puma, { Silent: true }
        Capybara::Server.new(Rails.application).boot.tap do |server|
          ENV['ATLAS_URL']   = "http://#{server.host}:#{server.port}"
          ENV['ATLAS_TOKEN'] = ATLAS_RB_SERVER_TOKEN
        end
      end
    end
  end
end

RSpec.configure do |config|
  config.before(:each, :atlas_rb_server) do
    AtlasRbServer.boot

    allow(Rails.application.credentials)
      .to receive(:cerberus_token).and_return(ATLAS_RB_SERVER_TOKEN)

    User.find_by_nuid(ATLAS_RB_SERVER_ADMIN_NUID) ||
      User.create!(email: 'admin-atlas-rb@example.invalid', password: SecureRandom.hex(16),
                   nuid: ATLAS_RB_SERVER_ADMIN_NUID, name: 'User, Admin', role: :admin)
  end

  config.after(:each, :atlas_rb_server) do
    Atlas.persister.wipe!
  end
end
