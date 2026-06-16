# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'FileSets via atlas_rb', :atlas_rb_server do
  let(:admin_nuid) { '000000004' }

  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  it 'round-trips a FileSet through the HTTP boundary' do
    created = AtlasRb::FileSet.create(work.noid, 'generic', nuid: admin_nuid)
    expect(created['id']).to be_present

    found = AtlasRb::FileSet.find(created['id'], nuid: admin_nuid)
    expect(found['id']).to eq(created['id'])
  end

  it 'creates an ordered (multipage) FileSet with a position' do
    created = AtlasRb::FileSet.create(work.noid, 'image', position: 2, nuid: admin_nuid)

    expect(created['position']).to eq(2)
    expect(FileSet.find(created['id']).position).to eq(2)
  end

  it 'leaves position nil when the kwarg is omitted' do
    created = AtlasRb::FileSet.create(work.noid, 'generic', nuid: admin_nuid)
    expect(created['position']).to be_nil
  end

  it 'attaches binary content to a FileSet via multipart update' do
    file_set = FileSetCreator.call(work_id: work.noid, classification: Classification.generic)

    AtlasRb::FileSet.update(file_set.noid, Rails.root.join('spec/fixtures/files/example.bin').to_s, nuid: admin_nuid)

    expect(FileSet.find(file_set.noid).children.size).to be >= 1
  end

  it 'destroys a FileSet via HTTP' do
    file_set = FileSetCreator.call(work_id: work.noid, classification: Classification.generic)

    AtlasRb::FileSet.destroy(file_set.noid, nuid: admin_nuid)
    expect(FileSet.find(file_set.noid)).to be_nil
  end

  # atlas_rb 1.3.6 — per-page IIIF service pointer (manifest assembly).
  describe '.set_iiif_service' do
    it 'persists the service pointer and surfaces it in the ordered page listing' do
      page = AtlasRb::FileSet.create(work.noid, 'image', position: 1, nuid: admin_nuid)
      uri  = 'https://iiif.example/iiif/3/page1.jp2'

      AtlasRb::FileSet.set_iiif_service(page['id'], uri, nuid: admin_nuid)

      pages = AtlasRb::Work.file_sets(work.noid, nuid: admin_nuid)
      page_entry = pages.find { |p| p['noid'] == page['id'] }
      expect(page_entry['assets'].pluck('uri')).to include(uri)
      expect(page_entry['assets'].pluck('use')).to include(Role.service_file.name)
    end

    it 'upserts in place — repeated calls hold one Delegate with the latest URI' do
      page = AtlasRb::FileSet.create(work.noid, 'image', position: 1, nuid: admin_nuid)

      AtlasRb::FileSet.set_iiif_service(page['id'], 'https://iiif.example/iiif/3/page1.jp2', nuid: admin_nuid)
      AtlasRb::FileSet.set_iiif_service(page['id'], 'https://iiif.example/iiif/3/page1.jp2?v2', nuid: admin_nuid)

      reloaded = FileSet.find(page['id'])
      deriv_fs = reloaded.children.find { |c| c.is_a?(FileSet) && c.type == Classification.derivative.name }
      members  = Atlas.query.find_members(resource: deriv_fs).to_a.select { |m| m.is_a?(Delegate) }
      expect(members.size).to eq(1)
      expect(members.first.uri).to eq('https://iiif.example/iiif/3/page1.jp2?v2')
    end
  end

  # atlas_rb 1.6.0 — the ordered attach is now resumable (Idempotency-Key),
  # filename-preserving (original_filename), and fixity-verifiable
  # (expected_digest). Requires Atlas v0.6.74's PATCH /file_sets/{id}.
  describe '.update (binary attach gap closures)' do
    let(:fixture) { Rails.root.join('spec/fixtures/files/example.bin').to_s }

    it 'retains original_filename and is idempotent on the key (replay does not recopy)' do
      file_set = FileSetCreator.call(work_id: work.noid, classification: Classification.generic)
      key      = SecureRandom.uuid

      2.times do
        AtlasRb::FileSet.update(file_set.noid, fixture,
                                original_filename: 'page-0001.tif',
                                idempotency_key: key, nuid: admin_nuid)
      end

      reloaded = FileSet.find(file_set.noid)
      expect(reloaded.content_files.size).to eq(1)
      expect(reloaded.content_files.first.original_filename).to eq('page-0001.tif')
    end

    it 'raises FixityMismatchError on an expected_digest mismatch and persists nothing' do
      file_set = FileSetCreator.call(work_id: work.noid, classification: Classification.generic)

      expect do
        AtlasRb::FileSet.update(file_set.noid, fixture,
                                expected_digest: "sha256:#{'0' * 64}", nuid: admin_nuid)
      end.to raise_error(AtlasRb::FixityMismatchError) { |e| expect(e.code).to eq('fixity_mismatch') }

      expect(FileSet.find(file_set.noid).content_files).to be_empty
    end
  end
end
