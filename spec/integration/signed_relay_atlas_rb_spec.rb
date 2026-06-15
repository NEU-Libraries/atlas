# frozen_string_literal: true

require 'rails_helper'

# End-to-end proof of the relay-signing path through the published atlas_rb gem.
# The :atlas_rb_server harness configures the gem to sign and stubs the matching
# public key into Atlas's credentials.cerberus_signing_keys, so a `nuid:` is
# signed into an assertion (sub = that nuid) the live server verifies — no
# ATLAS_TOKEN, no User header. This is the cryptographic replacement for the
# retired cerberus_token relay. (Acting-as via a signed `obo` claim is covered by
# signed_obo_atlas_rb_spec.)
RSpec.describe 'Signed-relay access via atlas_rb', :atlas_rb_server do
  let(:admin_nuid) { '000000004' } # seeded admin; the harness configures signing

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
end
