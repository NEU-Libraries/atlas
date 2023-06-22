# frozen_string_literal: true

# Generated with `rails generate valkyrie:model FileSet`
require 'rails_helper'
require 'valkyrie/specs/shared_specs'

RSpec.describe FileSet do
  let(:community) { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work) { WorkCreator.call(parent_id: collection.noid) }

  let(:file_set) { FileSetCreator.call(work_id: work.noid, classification: Classification.generic) }
  let(:resource_klass) { described_class }

  it_behaves_like 'a Valkyrie::Resource'

  describe '#files' do
    it 'returns Blob objects whose ids are in member_ids' do
      expect(file_set.files).to be_empty
      # puts file_set.files.inspect
    end
  end
end
