# frozen_string_literal: true

require 'rails_helper'

# End-to-end proof of the relay-SIGNING path through the published atlas_rb gem
# (>= 1.3.8). With a signing key configured, atlas_rb signs a short-lived ES256
# assertion (sub = acting nuid) instead of sending ATLAS_TOKEN + a `User:`
# header; Atlas verifies it against the public key in
# credentials.cerberus_signing_keys. This is step B's gem half proven against
# the live verifier — the cryptographic replacement for the cerberus_token
# relay. The Puma server and this test share one process, so the keypair
# generated here lines up on both sides.
RSpec.describe 'Signed-relay access via atlas_rb', :atlas_rb_server do
  let(:admin_nuid)  { '000000004' } # seeded admin (harness)
  let(:kid)         { 'cerberus-test' }
  let(:signing_key) { OpenSSL::PKey::EC.generate('prime256v1') }

  # Configure atlas_rb to SIGN, then reset — AtlasRb.config is a global
  # singleton, so leaking it would flip every other integration spec off the
  # default ATLAS_TOKEN relay.
  around do |example|
    saved_key = AtlasRb.config.assertion_signing_key
    saved_kid = AtlasRb.config.assertion_signing_kid
    AtlasRb.config.assertion_signing_key = signing_key
    AtlasRb.config.assertion_signing_kid = kid
    example.run
  ensure
    AtlasRb.config.assertion_signing_key = saved_key
    AtlasRb.config.assertion_signing_kid = saved_kid
  end

  # The Atlas server (same process) verifies against the matching public key.
  before do
    allow(Rails.application.credentials)
      .to receive(:cerberus_signing_keys)
      .and_return({ kid => signing_key.public_to_pem })
  end

  it 'authenticates a relayed read by signed assertion (no User header)' do
    community  = CommunityCreator.call
    collection = CollectionCreator.call(parent_id: community.noid)
    work       = WorkCreator.call(parent_id: collection.noid)

    found = AtlasRb::Work.find(work.noid, nuid: admin_nuid) # gem signs sub=admin_nuid
    expect(found['id']).to eq(work.noid)
  end

  it 'resolves identity from the signed sub' do
    me = AtlasRb::Authentication.login(admin_nuid)
    expect(me['nuid']).to eq(admin_nuid)
  end

  it 'permits a write under the signed relay (the operator is the proven sub)' do
    community  = CommunityCreator.call
    collection = CollectionCreator.call(parent_id: community.noid)

    work = AtlasRb::Work.create(collection.noid, nuid: admin_nuid)
    expect(work['id']).to be_present
  end

  it 'falls back to the cerberus_token relay for acting-as, which still works (not 403)' do
    community  = CommunityCreator.call
    collection = CollectionCreator.call(parent_id: community.noid)
    target     = '900000001'

    # Signing is configured, but On-Behalf-Of forces the legacy relay (Atlas
    # 403s acting-as on the assertion path). A created work — attributed to the
    # target — proves the gem fell back rather than signing.
    work = AtlasRb::Work.create(collection.noid, nuid: admin_nuid, on_behalf_of: target)
    expect(work['id']).to be_present
    expect(work['depositor']).to eq(target)
  end
end
