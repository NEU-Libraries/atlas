# frozen_string_literal: true

require 'rails_helper'

# atlas_rb — AtlasRb::Work.file_revisions wraps WorksController#file_revisions,
# the work page's general-audience replacement history. Exercised through the
# live server so the binding's URL, its read gate and its 404 → nil are proven
# against the real endpoint rather than a stub.
RSpec.describe 'Work file revisions via atlas_rb', :atlas_rb_server do
  let(:admin_nuid) { ATLAS_RB_SERVER_ADMIN_NUID }
  let(:fixture_a)  { Rails.root.join('spec/fixtures/files/example.bin').to_s }
  let(:fixture_b)  { Rails.root.join('spec/fixtures/files/example.png').to_s }
  let(:collection) { CollectionCreator.call(parent_id: public_community!.noid) }
  let!(:reader) do
    User.create!(email: 'file-revisions-reader@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000781', name: 'Doe, Reader', role: :standard, groups: [])
  end

  def work_with_replaced_file(visibility)
    work = WorkCreator.call(parent_id: collection.noid)
    work.public_send(visibility)
    work = Atlas.persister.save(resource: work)
    blob = AtlasRb::Blob.create(work.noid, fixture_a, 'example.bin', nuid: admin_nuid)
    AtlasRb::Blob.update(blob['id'], fixture_b, nuid: admin_nuid)
    AtlasRb::Blob.create(work.noid, fixture_a, 'never-replaced.bin', nuid: admin_nuid)
    [work, blob]
  end

  it 'gives a reader of a public Work the dates of its replaced file, and nothing more' do
    work, blob = work_with_replaced_file(:publicize)

    entries = AtlasRb::Work.file_revisions(work.noid, nuid: reader.nuid)
    expect(entries.map(&:blob_id)).to eq([blob['id']])

    revisions = entries.first.revisions
    expect(revisions.map(&:revision)).to eq([2, 1])
    expect(revisions.map(&:created)).to all(be_present)
    expect(revisions.map(&:keys)).to all(contain_exactly('revision', 'created'))
  end

  it 'raises ResourceError 403 for a caller who cannot read the Work' do
    work, = work_with_replaced_file(:privatize)

    expect { AtlasRb::Work.file_revisions(work.noid, nuid: reader.nuid) }
      .to raise_error(AtlasRb::ResourceError) { |error| expect(error.status).to eq(403) }
  end

  it 'answers [] for a Work whose files were never replaced, and nil for an unknown id' do
    work = WorkCreator.call(parent_id: collection.noid)
    AtlasRb::Blob.create(work.noid, fixture_a, 'example.bin', nuid: admin_nuid)

    expect(AtlasRb::Work.file_revisions(work.noid, nuid: admin_nuid)).to eq([])
    expect(AtlasRb::Work.file_revisions('doesnotexist', nuid: admin_nuid)).to be_nil
  end
end
