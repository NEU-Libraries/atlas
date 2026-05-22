# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Delegates via atlas_rb', :atlas_rb_server do
  let(:admin_nuid) { '000000004' }

  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  it 'finds a Delegate by NOID and unwraps the response shape' do
    delegate = DelegateCreator.call(
      resource_id: work.id,
      use:         Role.thumbnail_image.name,
      uri:         'https://iiif.example/iiif/3/abc.jp2/full/!85,85/0/default.jpg'
    )

    found = AtlasRb::Delegate.find(delegate.noid, nuid: admin_nuid)
    expect(found['id']).to        eq(delegate.noid)
    expect(found['use']).to       eq(Role.thumbnail_image.name)
    expect(found['uri']).to       eq('https://iiif.example/iiif/3/abc.jp2/full/!85,85/0/default.jpg')
    expect(found['tombstoned']).to eq(false)
  end

  it 'follows the /resources/:noid redirect for a Delegate' do
    delegate = DelegateCreator.call(
      resource_id: work.id,
      use:         Role.preview_image.name,
      uri:         'https://iiif.example/iiif/3/abc.jp2/full/500,/0/default.jpg'
    )

    # Resource.find resolves any NOID via the /resources/:id endpoint, which
    # 302-redirects to /delegates/:valkyrie_id for Delegate NOIDs. Faraday's
    # follow_redirects middleware (already wired into atlas_rb) handles the
    # hop transparently. Resource.find wraps the result with `klass` + the
    # type-key payload.
    found = AtlasRb::Resource.find(delegate.noid, nuid: admin_nuid)
    expect(found['klass']).to                eq('Delegate')
    expect(found['resource']['id']).to       eq(delegate.noid)
    expect(found['resource']['uri']).to      eq('https://iiif.example/iiif/3/abc.jp2/full/500,/0/default.jpg')
  end
end
