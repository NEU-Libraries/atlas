# frozen_string_literal: true

require 'rails_helper'

# End-to-end proof of the JWT-direct path through the published atlas_rb gem
# (>= 1.3.7, BYO-JWT mode). A personal-access JWT minted by Atlas is exported
# as ATLAS_JWT; atlas_rb then authenticates with it directly — no `User:`
# header, identity is in the token — exactly the standalone-script scenario
# (the fast_mods_v3.sh successor: a librarian pulling content with their own
# token). The Puma server and this test run in one process and share the same
# Warden::JWTAuth config, so a token minted here verifies on the server.
RSpec.describe 'JWT-direct access via atlas_rb', :atlas_rb_server do
  let(:admin_nuid) { '000000004' } # seeded by the :atlas_rb_server harness

  # A real, non-admin person — used to prove identity comes from the token.
  let!(:librarian) do
    User.create!(email: 'lib@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000077', name: 'Librarian, A', role: :standard)
  end

  def mint_jwt(user)
    Warden::JWTAuth::UserEncoder.new.call(user, :user, nil)[0]
  end

  # Swap the relay token (set by the harness) for a personal JWT for the
  # duration of the block, then restore so other examples keep relay mode.
  def with_jwt(token)
    saved = ENV.fetch('ATLAS_JWT', nil)
    ENV['ATLAS_JWT'] = token
    yield
  ensure
    saved.nil? ? ENV.delete('ATLAS_JWT') : ENV['ATLAS_JWT'] = saved
  end

  it 'resolves identity from the token, ignoring any nuid argument' do
    with_jwt(mint_jwt(librarian)) do
      # The nuid arg is bogus and must be ignored on the JWT path — the server
      # resolves the user encoded in the token, not the header.
      me = AtlasRb::Authentication.login('999999999')
      expect(me['nuid']).to eq(librarian.nuid)
    end
  end

  it 'reads a Work and lists children with only a JWT (no User header, no relay token)' do
    community  = CommunityCreator.call
    collection = CollectionCreator.call(parent_id: community.noid)
    work       = WorkCreator.call(parent_id: collection.noid)

    with_jwt(mint_jwt(User.find_by(nuid: admin_nuid))) do
      found = AtlasRb::Work.find(work.noid) # no nuid: kwarg
      expect(found['id']).to eq(work.noid)

      # The authenticated list call returns the Collection's one Work child.
      children = AtlasRb::Collection.children(collection.noid)
      expect(children.size).to eq(1)
    end
  end

  it "fetches a Work's MODS under a JWT (the fast_mods_v3.sh successor)" do
    community  = CommunityCreator.call
    collection = CollectionCreator.call(parent_id: community.noid)
    work       = WorkCreator.call(parent_id: collection.noid)

    with_jwt(mint_jwt(User.find_by(nuid: admin_nuid))) do
      expect(AtlasRb::Work.mods(work.noid)).to be_present
    end
  end

  it 'rejects a revoked token end-to-end after the jti is rotated' do
    token = mint_jwt(librarian)
    User.revoke_jwt(nil, librarian) # rotate jti → outstanding tokens die

    # The refusal reaches the caller as a typed error naming the status. It
    # used to arrive as a Mash carrying the 401 envelope, which reads like a
    # user record with no nuid — a dead token that looked like a live guest.
    with_jwt(token) do
      expect { AtlasRb::Authentication.login('000000077') }
        .to raise_error(AtlasRb::ResourceError) { |error| expect(error.status).to eq(401) }
    end
  end
end
