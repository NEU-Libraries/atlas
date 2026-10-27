# frozen_string_literal: true

require 'rails_helper'

# The preview image's size and placeholder, written through
# AtlasRb::Resource.set_thumbnails and read back through the typed finds.
RSpec.describe 'Preview size and placeholder via atlas_rb', :atlas_rb_server do
  let(:admin_nuid)  { '000000004' }
  let(:community)   { CommunityCreator.call }
  let(:collection)  { CollectionCreator.call(parent_id: community.noid) }
  let(:work)        { WorkCreator.call(parent_id: collection.noid) }
  let(:preview_uri) { 'https://iiif.example/iiif/3/abc.jp2/full/500,/0/default.jpg' }
  let(:placeholder) { Base64.strict_encode64("\xFF\xD8\xFF\xE0tiny".b) }
  let(:facts)       { { preview_width: 500, preview_height: 375, preview_placeholder: placeholder } }

  def preview_facts(found)
    found.to_h.slice('preview_width', 'preview_height', 'preview_placeholder')
  end

  def described
    { 'preview_width' => 500, 'preview_height' => 375, 'preview_placeholder' => placeholder }
  end

  def blank
    { 'preview_width' => nil, 'preview_height' => nil, 'preview_placeholder' => nil }
  end

  it 'answers nil for each fact on a resource with no preview' do
    expect(preview_facts(AtlasRb::Work.find(work.noid, nuid: admin_nuid))).to eq(blank)
  end

  it 'returns the facts on the write response and on the next Work find' do
    written = AtlasRb::Resource.set_thumbnails(work.noid, preview: preview_uri, **facts, nuid: admin_nuid)
    expect(preview_facts(written)).to eq(described)

    found = AtlasRb::Work.find(work.noid, nuid: admin_nuid)
    expect(found['preview']).to eq(preview_uri)
    expect(preview_facts(found)).to eq(described)
  end

  it 'returns them on a Collection find and a Community find' do
    AtlasRb::Resource.set_thumbnails(collection.noid, preview: preview_uri, **facts, nuid: admin_nuid)
    AtlasRb::Resource.set_thumbnails(community.noid, preview: preview_uri, **facts, nuid: admin_nuid)

    expect(preview_facts(AtlasRb::Collection.find(collection.noid, nuid: admin_nuid))).to eq(described)
    expect(preview_facts(AtlasRb::Community.find(community.noid, nuid: admin_nuid))).to eq(described)
  end

  # A regenerated derivative can keep its IIIF URI and change its size, so a
  # preview write without the facts must not keep the old image's.
  it 'clears the facts when the preview is written again without them' do
    AtlasRb::Resource.set_thumbnails(work.noid, preview: preview_uri, **facts, nuid: admin_nuid)
    AtlasRb::Resource.set_thumbnails(work.noid, preview: preview_uri, nuid: admin_nuid)

    found = AtlasRb::Work.find(work.noid, nuid: admin_nuid)
    expect(found['preview']).to eq(preview_uri)
    expect(preview_facts(found)).to eq(blank)
  end

  it 'keeps the facts when only another tier is written' do
    AtlasRb::Resource.set_thumbnails(work.noid, preview: preview_uri, **facts, nuid: admin_nuid)
    AtlasRb::Resource.set_thumbnails(work.noid, thumbnail: 'https://iiif.example/85.jpg', nuid: admin_nuid)

    expect(preview_facts(AtlasRb::Work.find(work.noid, nuid: admin_nuid))).to eq(described)
  end

  it 'raises a 422 ResourceError naming the fault, and writes nothing' do
    error = nil
    begin
      AtlasRb::Resource.set_thumbnails(work.noid, preview: preview_uri, preview_width: 500, nuid: admin_nuid)
    rescue AtlasRb::ResourceError => e
      error = e
    end

    expect(error&.status).to eq(422)
    expect(JSON.parse(error.body)['error']).to eq('preview_dimensions_incomplete')
    expect(AtlasRb::Work.find(work.noid, nuid: admin_nuid)['preview']).to be_nil
  end

  it 'refuses the facts sent without the preview they describe' do
    expect { AtlasRb::Resource.set_thumbnails(work.noid, **facts, nuid: admin_nuid) }
      .to raise_error(AtlasRb::ResourceError) { |e| expect(JSON.parse(e.body)['error']).to eq('preview_required') }
  end
end
