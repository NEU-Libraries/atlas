# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Modsable do
  let(:community) { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work) { WorkCreator.call(parent_id: collection.noid) }

  describe '#mods_xml=' do
    it 'stores the descriptive-metadata blob under the canonical descMetadata.xml filename' do
      stored_id = work.mods_blob.file_identifiers.last.to_s
      expect(stored_id).to end_with('/descMetadata.xml')
    end
  end
end
