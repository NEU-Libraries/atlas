# frozen_string_literal: true

require 'rails_helper'

describe FileSetsController, type: :controller do
  render_views

  let(:community) { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work) { WorkCreator.call(parent_id: collection.noid) }

  describe 'GET #show' do
  end

  describe 'GET #index' do
  end

  describe 'POST #create' do
    it 'creates a FileSet with provided work id as parent' do
      post :create, params: { work_id: work.noid, classification: Classification.generic.to_s }
      expect(response).to have_http_status(:success)
      # TODO: Test id is returned and resolves to resource
    end
  end

  describe 'PATCH #update' do
  end

  describe 'DELETE #destroy' do
  end
end
