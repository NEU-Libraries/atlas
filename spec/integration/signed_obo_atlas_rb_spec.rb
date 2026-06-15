# frozen_string_literal: true

require 'rails_helper'

# End-to-end proof of acting-as over the signed-assertion path through the
# atlas_rb gem. The :atlas_rb_server harness configures the gem to sign; an
# on_behalf_of request is signed with `sub` = operator and an `obo` claim =
# target, and live Atlas admin-gates the operator and attributes the deposit to
# the target — no On-Behalf-Of header in flight; acting-as lives entirely inside
# the signed assertion.
RSpec.describe 'Signed-obo acting-as via atlas_rb', :atlas_rb_server do
  let(:admin_nuid) { '000000004' } # seeded admin operator; the harness configures signing
  let(:target)     { '900000001' } # attribution target (need not exist)

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
