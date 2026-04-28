# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'Resources', type: :request do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  after { Atlas.persister.wipe! }

  path '/resources/{id}' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of any resource (Work, Collection, Community, FileSet)'

    get 'Resolve a resource by NOID' do
      tags 'Resources'
      produces 'application/json'
      description 'Generic resolver. Issues a 302 redirect to the typed endpoint (e.g. `/works/{id}`).'

      response '302', 'redirect to typed resource' do
        let(:id) { work.noid }
        run_test!
      end
    end
  end

  path '/resources/{id}/permissions' do
    parameter name: :id, in: :path, type: :string

    get 'Permission flags for a resource' do
      tags 'Resources'
      produces 'application/json'

      response '200', 'permissions returned' do
        let(:id) { work.noid }
        schema '$ref' => '#/components/schemas/Permissions'
        run_test!
      end
    end
  end

  path '/resources/preview' do
    post 'Render a temporary resource preview' do
      tags 'Resources'
      consumes 'multipart/form-data'
      produces 'text/html'
      description 'Given raw MODS XML, renders an HTML preview without persisting. Used by the loader/editor surface.'
      parameter name: :binary, in: :formData, required: true
      multipart_request_body(
        { binary: { type: :string, format: :binary, description: 'MODS XML to preview' } },
        required: %i[binary]
      )

      response '200', 'preview rendered' do
        let(:binary) { Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/work-mods.xml')) }
        run_test!
      end
    end
  end
end
