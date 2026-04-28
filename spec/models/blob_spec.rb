# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Blob do
  let(:community) { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work) { WorkCreator.call(parent_id: collection.noid) }

  describe '#path' do
    it 'returns nil when no file has been uploaded' do
      expect(Blob.new.path).to be_nil
    end

    it 'returns the on-disk path of the latest revision' do
      path = work.mods_blob.path
      expect(path).to be_a(String)
      expect(File).to exist(path)
      expect(path).to end_with('descMetadata.xml')
    end
  end
end
