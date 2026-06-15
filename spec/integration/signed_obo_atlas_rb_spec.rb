# frozen_string_literal: true

require 'rails_helper'

# End-to-end proof of acting-as over the signed-assertion path through the
# published atlas_rb gem (>= 1.3.9). With signing configured, an on_behalf_of
# request is signed with `sub` = operator and a `obo` claim = target; Atlas
# admin-gates the operator and attributes the deposit to the target — no
# On-Behalf-Of header in flight. This closes the last capability of the
# cerberus_token relay (acting-as) on the cryptographic path.
RSpec.describe 'Signed-obo acting-as via atlas_rb', :atlas_rb_server do
  let(:admin_nuid)  { '000000004' } # seeded admin operator (harness)
  let(:target)      { '900000001' } # attribution target (need not exist)
  let(:kid)         { 'cerberus-test' }
  let(:signing_key) { OpenSSL::PKey::EC.generate('prime256v1') }

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

  before do
    allow(Rails.application.credentials)
      .to receive(:cerberus_signing_keys)
      .and_return({ kid => signing_key.public_to_pem })
  end

  it 'signs an obo claim for acting-as — Atlas attributes the deposit to the target' do
    community  = CommunityCreator.call
    collection = CollectionCreator.call(parent_id: community.noid)

    work = AtlasRb::Work.create(collection.noid, nuid: admin_nuid, on_behalf_of: target)
    expect(work['id']).to be_present
    expect(work['depositor']).to eq(target) # acting-as attribution
    expect(work['proxy_uploader']).to be_nil # nulled under impersonation
  end

  it 'omits obo for a non-acting-as signed create — deposit attributed to the operator' do
    community  = CommunityCreator.call
    collection = CollectionCreator.call(parent_id: community.noid)

    work = AtlasRb::Work.create(collection.noid, nuid: admin_nuid)
    expect(work['id']).to be_present
    expect(work['depositor']).to eq(admin_nuid)
  end
end
