# frozen_string_literal: true

require 'rails_helper'

# atlas_rb's preview and format-list bindings end to end through the live
# server. See docs/metadata-records.md.
RSpec.describe 'Metadata format previews via atlas_rb', :atlas_rb_server do
  let(:admin_nuid) { ATLAS_RB_SERVER_ADMIN_NUID }

  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  def fixture(name)
    Rails.root.join('spec/fixtures/files', name).to_s
  end

  it 'lists every previewable format, MODS first' do
    formats = AtlasRb::Resource.metadata_formats(nuid: admin_nuid)

    expect(formats.pluck('id')).to eq(MetadataRecords.previewable.map(&:token))
    expect(formats.first.to_h).to eq('id' => 'mods', 'label' => 'MODS', 'media_type' => 'application/xml')
  end

  it 'previews MODS when no format is named' do
    html = AtlasRb::Resource.preview(fixture('work-mods.xml'), nuid: admin_nuid)

    expect(html).to include('id="mods"')
  end

  it 'previews a Darwin Core draft as the stored record renders, and saves nothing' do
    AtlasRb::Resource.put_dwc(work.noid, fixture('dwc.xml'), nuid: admin_nuid)
    stored = AtlasRb::Work.dwc(work.noid, 'html', nuid: admin_nuid)
    rows = Metadata::DarwinCore.count

    html = AtlasRb::Resource.preview(fixture('dwc.xml'), metadata_format: 'dwc', nuid: admin_nuid)

    expect(html).to eq(stored)
    expect(Metadata::DarwinCore.count).to eq(rows)
  end

  it 'raises on a refused draft, with the rule in the body' do
    expect { AtlasRb::Resource.preview(fixture('dwc-two-records.xml'), metadata_format: 'dwc', nuid: admin_nuid) }
      .to raise_error(AtlasRb::ResourceError) { |e|
        expect(e.status).to eq(422)
        expect(JSON.parse(e.body)['error']).to eq('record_count')
      }
  end
end
