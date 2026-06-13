# frozen_string_literal: true

require 'rails_helper'

# Regression for the Cerberus-side gap report dated 2026-05-22 evening:
# two sequential `AtlasRb::Community.create(nil, xml_path, nuid: admin_nuid)`
# calls within the same test process fail on the second one's PATCH with a
# 500 / wrong-type return from `Community.find(params[:id])` inside
# CommunitiesController#update.
#
# atlas_rb's Community.create is POST → PATCH → GET; the PATCH is the failing
# step. The spec drives the same shape Cerberus's `let` blocks produce (each
# spec creates Community → Collection → Work back-to-back via atlas_rb).
RSpec.describe 'Sequential AtlasRb::*.create regression', :atlas_rb_server do
  let(:admin_nuid) { '000000004' }

  let(:mods_path) do
    path = Rails.root.join('tmp/sequential-create-spec.xml').to_s
    File.write(path,
               '<?xml version="1.0" encoding="UTF-8"?>' \
               '<mods xmlns="http://www.loc.gov/mods/v3">' \
               '<titleInfo><title>x</title></titleInfo>' \
               '</mods>')
    path
  end

  it 'creates two Communities back-to-back via the HTTP boundary' do
    c1 = AtlasRb::Community.create(nil, mods_path, nuid: admin_nuid)
    expect(c1['id']).to be_present

    c2 = AtlasRb::Community.create(nil, mods_path, nuid: admin_nuid)
    expect(c2['id']).to be_present

    expect(c1['id']).not_to eq(c2['id'])
  end

  it 'creates Community → Collection → Work back-to-back (Cerberus let-block shape)' do
    community  = AtlasRb::Community.create(nil, mods_path, nuid: admin_nuid)
    collection = AtlasRb::Collection.create(community['id'], mods_path, nuid: admin_nuid)
    work       = AtlasRb::Work.create(collection['id'], mods_path, nuid: admin_nuid)

    expect(community['id']).to be_present
    expect(collection['id']).to be_present
    expect(work['id']).to be_present
  end

  it 'survives ten Community → Collection → Work cycles back-to-back (suite-shape)' do
    10.times do |i|
      community  = AtlasRb::Community.create(nil, mods_path, nuid: admin_nuid)
      collection = AtlasRb::Collection.create(community['id'], mods_path, nuid: admin_nuid)
      work       = AtlasRb::Work.create(collection['id'], mods_path, nuid: admin_nuid)

      expect(community['id']).to be_present, "cycle #{i}: community failed"
      expect(collection['id']).to be_present, "cycle #{i}: collection failed"
      expect(work['id']).to be_present, "cycle #{i}: work failed"
    end
  end
end
