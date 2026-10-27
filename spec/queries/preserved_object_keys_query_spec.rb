# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PreservedObjectKeysQuery do
  let(:work) { WorkCreator.call(parent_id: CollectionCreator.call(parent_id: CommunityCreator.call.noid).noid) }

  after { Atlas.persister.wipe! }

  before do
    BlobCreator.call(work_id: work.noid, path: Rails.root.join('spec/fixtures/files/example.png').to_s,
                     original_filename: 'example.png')
    DelegateCreator.call(resource_id: work.id, use: Role.thumbnail_image.name, uri: 'https://iiif.example/t.jpg')
  end

  # The rollup and the health check must count the same objects.
  it 'names the same objects as Work#preserved_resources' do
    expected = Work.find(work.noid).preserved_resources.map(&:noid)

    expect(described_class.keys_for(work)).to match_array(expected)
  end

  it 'leaves out the Derivative FileSet and its Delegates' do
    derivative = Work.find(work.noid).children.find { |c| c.is_a?(FileSet) && !Classification.preserved?(c.type) }
    keys = described_class.keys_for(work)

    expect(derivative).to be_present
    expect(keys).not_to include(derivative.noid, *derivative.files.compact.map(&:noid))
  end
end
