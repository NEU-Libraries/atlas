# frozen_string_literal: true

require 'rails_helper'

describe BlobsController, type: :controller do
  render_views

  let(:community) { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work) { WorkCreator.call(parent_id: collection.noid) }
  # let(:file_set) { FileSetCreator.call(work_id: work.noid, classification: Classification.generic) }

  describe 'GET #show' do
    let(:blob) { BlobCreator.call(path: Rails.root.join('spec/fixtures/files/image.png').to_s, work_id: work.noid) }

    context 'when the blob exists' do
      it 'returns the blob details' do
        get :show, params: { id: blob.noid }, as: :json
        expect(response).to have_http_status(:success)

        json_response = response.parsed_body
        expect(json_response['blob']['id']).to eq(blob.noid)
      end
    end
  end

  describe 'GET #index' do
  end

  describe 'POST #create' do
  end

  describe 'PATCH #update' do
  end

  describe 'DELETE #destroy' do
  end
end
