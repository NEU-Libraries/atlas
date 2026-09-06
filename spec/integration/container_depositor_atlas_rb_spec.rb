# frozen_string_literal: true

require 'rails_helper'

# `depositor:` on AtlasRb::Collection.create / Community.create (atlas_rb 1.9.3),
# matching what Work.create has always supported. Atlas already read the param;
# only the bindings couldn't pass it.
#
# The case this exists for: a seed acts as an admin — the only identity whose
# wildcard carries a whole create sequence — while attributing institutional
# containers to the anonymous NUID, since nobody personally owns them and access
# is via Grouper groups. That separation matters now that a depositor carries
# edit rights on their own resource.
RSpec.describe 'Container depositor via atlas_rb', :atlas_rb_server do
  let(:admin_nuid)     { '000000004' }
  let(:anonymous_nuid) { '000000099' }

  let(:community) { CommunityCreator.call }

  it 'stamps an explicit depositor on a Collection while the admin authorizes the call' do
    created = AtlasRb::Collection.create(community.noid, depositor: anonymous_nuid, nuid: admin_nuid)

    expect(created['depositor']).to eq(anonymous_nuid)
    # Accurate provenance: nobody owns the container, and the admin is who
    # created it.
    expect(Collection.find(created['id']).proxy_uploader).to eq(admin_nuid)
  end

  it 'stamps an explicit depositor on a Community' do
    created = AtlasRb::Community.create(community.noid, depositor: anonymous_nuid, nuid: admin_nuid)

    expect(created['depositor']).to eq(anonymous_nuid)
  end

  it 'stamps an explicit depositor on a top-level Community' do
    created = AtlasRb::Community.create(nil, depositor: anonymous_nuid, nuid: admin_nuid)

    expect(created['depositor']).to eq(anonymous_nuid)
    expect(Community.find(created['id']).parent).to be_nil
  end

  it 'falls through to the acting user when depositor is omitted' do
    created = AtlasRb::Collection.create(community.noid, nuid: admin_nuid)

    expect(created['depositor']).to eq(admin_nuid)
  end

  it 'composes with the featured flag and a MODS seed' do
    created = AtlasRb::Collection.create(
      community.noid,
      Rails.root.join('spec/fixtures/files/work-mods.xml').to_s,
      featured: true, depositor: anonymous_nuid, nuid: admin_nuid
    )

    expect(created['depositor']).to eq(anonymous_nuid)
    expect(created['featured']).to be(true)
    expect(created['title']).to eq("What's New, Episode 1 - How We Respond to Disaster")
  end
end
