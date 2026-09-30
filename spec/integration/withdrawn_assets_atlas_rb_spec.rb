# frozen_string_literal: true

require 'rails_helper'

# The Restore round trip a caption editor makes: find the caption's FileSet on
# its asset entry, tombstone it, find it again on the withdrawn listing, and
# restore it from there.
RSpec.describe 'Withdrawn assets via atlas_rb', :atlas_rb_server do
  let(:nuid)       { '000000004' }
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }
  let(:fixture)    { Rails.root.join('spec/fixtures/files/example.bin').to_s }
  let!(:caption)   { BlobCreator.call(work_id: work.noid, original_filename: 'es.vtt', path: fixture) }

  it 'restores a tombstoned FileSet by the id the withdrawn listing names' do
    file_set = AtlasRb::Work.assets(work.noid, nuid: nuid).find { |a| a.noid == caption.noid }.file_set
    expect(file_set).to eq(caption.parent.noid)

    AtlasRb::Resource.tombstone(file_set, nuid: nuid)
    expect(AtlasRb::Work.assets(work.noid, nuid: nuid).map(&:noid)).not_to include(caption.noid)

    withdrawn = AtlasRb::Work.withdrawn_assets(work.noid, nuid: nuid)
    expect(withdrawn.map(&:noid)).to eq([caption.noid])
    expect(withdrawn.first.tombstoned_by).to eq(nuid)

    AtlasRb::Admin::Resource.restore(withdrawn.first.file_set, nuid: nuid)
    expect(AtlasRb::Work.withdrawn_assets(work.noid, nuid: nuid)).to eq([])
    expect(AtlasRb::Work.assets(work.noid, nuid: nuid).map(&:noid)).to include(caption.noid)
  end

  it 'returns nil for a Work that does not exist' do
    expect(AtlasRb::Work.withdrawn_assets('doesnotexist', nuid: nuid)).to be_nil
  end

  it 'raises ResourceError with a 403 for a caller below the delegate tier' do
    standard = User.create!(email: 'standard-withdrawn-rb@example.invalid', password: SecureRandom.hex(16),
                            nuid: '000000056', name: 'Roe, Sam', role: :standard, groups: [])

    expect { AtlasRb::Work.withdrawn_assets(work.noid, nuid: standard.nuid) }
      .to raise_error(AtlasRb::ResourceError) { |e| expect(e.status).to eq(403) }
  end
end
