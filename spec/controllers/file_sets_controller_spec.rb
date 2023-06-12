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
    context 'when file sets exist' do
      it 'returns a paginated list of all file sets' do
        12.times do
          FileSetCreator.call(work_id: work.noid, classification: Classification.generic)
        end

        get :index, as: :json
        expect(response).to have_http_status(:success)
        json_response = response.parsed_body
        expect(json_response['file_sets']).not_to be_empty
        # TODO: ensure pagination results are correct
      end
    end
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
