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
#
# Auth context: pre-piece-7 this harness used ATLAS_TOKEN='' so requests
# fell through to the guest user (which was sufficient because nothing was
# Ability-gated). Piece 7 introduced authorize! on every action, so guest
# can't write. The harness now stubs the cerberus token, seeds an admin
# fixture, and monkey-patches atlas_rb's connection helpers to inject the
# admin NUID into every call that doesn't supply one. Calls that DO supply
# an explicit nuid: keep that — tombstones_atlas_rb_spec exercises
# nuid-stamping with a non-admin actor.

require 'capybara'
require 'atlas_rb'

ATLAS_RB_SERVER_TOKEN = 'test-cerberus-token'
ATLAS_RB_SERVER_ADMIN_NUID = '000000004'

# Monkey-patch atlas_rb's per-resource connection/multipart helpers to default
# the User: header to the test admin when the caller didn't pass an explicit
# nuid. Atlas_rb 0.0.97 doesn't thread `nuid:` through every method, so this
# is the test-only equivalent of "default to admin" for the methods that
# don't accept a nuid kwarg.
module AtlasRbServerAdminDefault
  def connection(params, nuid = nil, **kwargs)
    super(params, nuid || ATLAS_RB_SERVER_ADMIN_NUID, **kwargs)
  end

  def multipart(nuid = nil, **kwargs)
    # atlas_rb 0.0.97 has a quirk: some call sites pass `multipart({})` rather
    # than `multipart(nil)`, binding {} to the nuid arg. The {} is truthy so
    # the gem's branch fires and sends "NUID {}" — wonky but the wire still
    # works pre-piece-7 because nothing read the header. Post-piece-7 the
    # admin default fires only when nuid is falsy or {}.
    nuid = nil if nuid.is_a?(Hash) && nuid.empty?
    super(nuid || ATLAS_RB_SERVER_ADMIN_NUID, **kwargs)
  end
end

[AtlasRb::Work, AtlasRb::Collection, AtlasRb::Community,
 AtlasRb::FileSet, AtlasRb::Blob, AtlasRb::Delegate,
 AtlasRb::Resource].each do |klass|
  klass.singleton_class.prepend(AtlasRbServerAdminDefault)
end

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
