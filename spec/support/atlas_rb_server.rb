# frozen_string_literal: true

# Tag-driven harness for integration specs that drive Atlas through the
# atlas_rb gem. Boots a real Puma server backed by the Rails app and points
# atlas_rb's ENV-driven Faraday connection at it.
#
# Usage:
#
#     RSpec.describe 'Communities', :atlas_rb_server do
#       it 'round-trips' do
#         AtlasRb::Community.create(nil)
#       end
#     end
#
# The server boots lazily on the first tagged example and is reused for the
# rest of the suite. Valkyrie state is wiped after each tagged example —
# transactional fixtures don't apply here, since the test thread and the
# server thread hold different AR connections.

require 'capybara'
require 'atlas_rb'

module AtlasRbServer
  class << self
    def boot
      @server ||= begin
        Capybara.server = :puma, { Silent: true }
        Capybara::Server.new(Rails.application).boot.tap do |server|
          ENV['ATLAS_URL']   = "http://#{server.host}:#{server.port}"
          # Empty token → ApplicationController falls through to guest_sign_in,
          # which is sufficient since these controllers do not gate on the user.
          ENV['ATLAS_TOKEN'] = ''
        end
      end
    end
  end
end

RSpec.configure do |config|
  config.before(:each, :atlas_rb_server) do
    AtlasRbServer.boot
  end

  config.after(:each, :atlas_rb_server) do
    Valkyrie.config.metadata_adapter.persister.wipe!
  end
end
