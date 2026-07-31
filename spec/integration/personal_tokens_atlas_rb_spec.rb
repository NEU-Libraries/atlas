# frozen_string_literal: true

require 'rails_helper'

# End-to-end proof of the personal-access token lifecycle binding
# (AtlasRb::System::Token) through the live server — the "My DRS → Programmatic
# access" cycle Cerberus drives post-SSO: mint a 1-week JWT for a real person,
# prove it authenticates that person in BYO-JWT mode, then revoke and prove the
# same token is dead. Also covers `read_only:` minting — the shape handed to a
# non-human caller (e.g. an Atlas MCP client) — proving the resulting token
# still authenticates but is blocked on a write regardless of the target
# user's own permissions. Both endpoints are :system-gated, so the binding
# runs on the system connection (system token + `User: NUID` header), never
# the ambient-user relay path.
RSpec.describe 'Personal-access token lifecycle via atlas_rb', :atlas_rb_server do
  # atlas_rb's system_connection reads its bearer from
  # credentials.atlas_system_token; the server validates it against
  # credentials.system_token. Client and server share one credentials object in
  # this process, so pointing both at the same secret makes the system call
  # authenticate as :system.
  let(:system_secret) { 'test-system-token' }

  # The :system fixture the server resolves from `User: NUID 000000000` (the
  # role-based pairing check in require_auth). The harness seeds only the admin,
  # so create the bookend here.
  let!(:system_user) do
    User.find_by(nuid: AtlasRb::System::NUID) ||
      User.create!(email: 'system@example.invalid', password: SecureRandom.hex(16),
                   nuid: AtlasRb::System::NUID, name: 'User, System', role: :system)
  end

  # A real, non-admin person to mint tokens for.
  let!(:librarian) do
    User.create!(email: 'lib@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000077', name: 'Librarian, A', role: :standard)
  end

  before do
    allow(Rails.application.credentials).to receive(:system_token).and_return(system_secret)
    allow(Rails.application.credentials).to receive(:atlas_system_token).and_return(system_secret)
  end

  # Swap in a personal JWT (BYO-JWT mode) for the block, then restore relay mode
  # so other examples keep signing assertions.
  def with_jwt(token)
    saved = ENV.fetch('ATLAS_JWT', nil)
    ENV['ATLAS_JWT'] = token
    yield
  ensure
    saved.nil? ? ENV.delete('ATLAS_JWT') : ENV['ATLAS_JWT'] = saved
  end

  it 'mints a JWT that authenticates as the target person in BYO-JWT mode' do
    token = AtlasRb::System::Token.mint(nuid: librarian.nuid)
    expect(token).to be_a(String).and be_present

    with_jwt(token) do
      # Identity comes from the token's sub — the bogus nuid arg is ignored.
      me = AtlasRb::Authentication.login('999999999')
      expect(me['nuid']).to eq(librarian.nuid)
    end
  end

  it 'revokes every outstanding token, killing it end-to-end' do
    token = AtlasRb::System::Token.mint(nuid: librarian.nuid)

    expect(AtlasRb::System::Token.revoke(nuid: librarian.nuid)).to be(true)

    with_jwt(token) do
      me = AtlasRb::Authentication.login(librarian.nuid)
      expect(me['nuid']).to be_nil      # jti rotated → token no longer valid
      expect(me['error']).to be_present # 401 envelope surfaced
    end
  end

  it 'regenerate (revoke then mint) issues a fresh token while the old one dies' do
    old = AtlasRb::System::Token.mint(nuid: librarian.nuid)
    AtlasRb::System::Token.revoke(nuid: librarian.nuid)
    fresh = AtlasRb::System::Token.mint(nuid: librarian.nuid)

    with_jwt(fresh) do
      expect(AtlasRb::Authentication.login('x')['nuid']).to eq(librarian.nuid)
    end
    with_jwt(old) do
      expect(AtlasRb::Authentication.login('x')['nuid']).to be_nil
    end
  end

  it 'mints a read_only token that authenticates but is blocked on a write' do
    token = AtlasRb::System::Token.mint(nuid: librarian.nuid, read_only: true)
    expect(token).to be_a(String).and be_present

    with_jwt(token) do
      me = AtlasRb::Authentication.login('999999999')
      expect(me['nuid']).to eq(librarian.nuid) # read-shaped call still works

      # librarian's own Ability grants :create, Community — the read_only floor
      # blocks it anyway, proving the restriction is independent of the resolved
      # user's real permissions. atlas_rb translates a refusal on the create
      # paths into a typed error rather than a nil unwrap.
      expect { AtlasRb::Community.create(nil) }.to raise_error(AtlasRb::ForbiddenError)
    end
  end

  it 'mint without read_only is unaffected (full privilege, as before)' do
    token = AtlasRb::System::Token.mint(nuid: librarian.nuid)

    with_jwt(token) do
      expect(AtlasRb::Community.create(nil)).to be_present
    end
  end

  it 'mint returns nil for an NUID with no Atlas User row (404)' do
    expect(AtlasRb::System::Token.mint(nuid: '111111111')).to be_nil
  end

  it 'revoke returns false for an NUID with no Atlas User row (404)' do
    expect(AtlasRb::System::Token.revoke(nuid: '111111111')).to be(false)
  end
end
