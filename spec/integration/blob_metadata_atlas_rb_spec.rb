# frozen_string_literal: true

require 'rails_helper'

# atlas_rb — Blob.update(original_filename:), the language: and track_label:
# keywords, and tombstoning a FileSet through Resource.tombstone and
# Admin::Resource.restore. Cerberus drives these for "Replace a file" and for
# captions in more than one language.
RSpec.describe 'Blob name, language and removal via atlas_rb', :atlas_rb_server do
  let(:admin_nuid) { '000000004' }

  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }
  let(:docx)       { Rails.root.join('spec/fixtures/files/example.docx').to_s }
  let(:pdf)        { Rails.root.join('spec/fixtures/files/example.pdf').to_s }
  let(:caption)    { Rails.root.join('spec/fixtures/files/example.bin').to_s }

  def asset(noid)
    AtlasRb::Work.assets(work.noid, nuid: admin_nuid).find { |a| a['noid'] == noid }
  end

  it 'renames the file on a replace, and a rollback restores the old name' do
    blob = AtlasRb::Blob.create(work.noid, docx, 'report.docx', nuid: admin_nuid)

    replaced = AtlasRb::Blob.update(blob['id'], pdf, original_filename: 'report.pdf', nuid: admin_nuid)['blob']
    expect(replaced).to include('original_filename' => 'report.pdf', 'mime_type' => 'application/pdf')
    expect(replaced['filename']).to end_with('.pdf')

    versions = AtlasRb::Blob.versions(blob['id'], nuid: admin_nuid)['versions']
    expect(versions.pluck('original_filename')).to eq(%w[report.pdf report.docx])

    AtlasRb::Blob.rollback(blob['id'], versions.last['version_id'], nuid: admin_nuid)
    expect(AtlasRb::Blob.find(blob['id'], nuid: admin_nuid)['original_filename']).to eq('report.docx')
  end

  it 'keeps the name when a replace does not send one' do
    blob = AtlasRb::Blob.create(work.noid, docx, 'report.docx', nuid: admin_nuid)

    expect(AtlasRb::Blob.update(blob['id'], docx, nuid: admin_nuid).dig('blob', 'original_filename'))
      .to eq('report.docx')
  end

  it 'records a caption language and label, and an update changes only what it sends' do
    blob = AtlasRb::Blob.create(work.noid, caption, 'es.vtt', language: 'es', track_label: 'Español',
                                                              nuid: admin_nuid)
    expect(asset(blob['id'])).to include('language' => 'es', 'track_label' => 'Español')

    AtlasRb::Blob.update(blob['id'], caption, language: 'es-MX', nuid: admin_nuid)
    expect(asset(blob['id'])).to include('language' => 'es-MX', 'track_label' => 'Español')

    AtlasRb::Blob.update(blob['id'], caption, track_label: '', nuid: admin_nuid)
    expect(asset(blob['id'])['track_label']).to be_nil
  end

  it 'raises ResourceError on a malformed language' do
    expect { AtlasRb::Blob.create(work.noid, caption, 'x.vtt', language: 'Spanish', nuid: admin_nuid) }
      .to raise_error(AtlasRb::ResourceError) { |e| expect(e.status).to eq(422) }
  end

  it 'withdraws a caption FileSet reversibly' do
    blob = AtlasRb::Blob.create(work.noid, caption, 'en.vtt', nuid: admin_nuid)
    file_set_id = Blob.find(blob['id']).parent.noid

    expect(AtlasRb::Resource.tombstone(file_set_id, nuid: admin_nuid).status).to eq(200)
    expect(asset(blob['id'])).to be_nil

    expect(AtlasRb::Admin::Resource.restore(file_set_id, nuid: admin_nuid).status).to eq(200)
    expect(asset(blob['id'])).to be_present
  end

  it 'accepts the former master tier key and stores it as original' do
    work.publicize
    Atlas.persister.save(resource: work)

    AtlasRb::Work.set_derivative_permissions(work.noid, policy: { master: ['grp:archives'] }, nuid: admin_nuid)

    expect(AtlasRb::Work.find(work.noid, nuid: admin_nuid)['derivative_permissions'])
      .to eq('original' => ['grp:archives'])
  end
end
