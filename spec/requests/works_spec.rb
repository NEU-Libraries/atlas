# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'Works', type: :request do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }

  after { Valkyrie.config.metadata_adapter.persister.wipe! }

  path '/works' do
    get 'List works' do
      tags 'Works'
      produces 'application/json'
      description 'Paginated list of all works.'

      response '200', 'works listed' do
        before { 2.times { WorkCreator.call(parent_id: collection.noid) } }
        schema '$ref' => '#/components/schemas/WorksIndex'
        run_test!
      end
    end

    post 'Create a work' do
      tags 'Works'
      consumes 'application/json'
      produces 'application/json'
      description 'Creates a new Work as a child of the given Collection.'
      parameter name: :body, in: :body, schema: {
        type: :object,
        properties: {
          collection_id: { type: :string, description: 'NOID of the parent Collection' }
        },
        required: %w[collection_id]
      }

      response '200', 'work created' do
        let(:body) { { collection_id: collection.noid } }
        schema '$ref' => '#/components/schemas/Work'
        run_test!
      end
    end
  end

  path '/works/{id}' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Work'

    get 'Retrieve a work' do
      tags 'Works'
      produces 'application/json'

      response '200', 'work found' do
        let(:work) { WorkCreator.call(parent_id: collection.noid) }
        let(:id)   { work.noid }
        schema '$ref' => '#/components/schemas/Work'
        run_test!
      end
    end

    patch 'Update a work' do
      tags 'Works'
      consumes 'multipart/form-data'
      produces 'application/json'
      description <<~D
        Updates a Work. Either supply a `binary` MODS XML upload or a
        `metadata[*]` hash of fields to merge in.
      D
      parameter name: :body, in: :body, schema: {
        type: :object,
        properties: {
          'metadata[title]':       { type: :string },
          'metadata[description]': { type: :string },
          'metadata[thumbnail]':   { type: :string },
          'metadata[permissions]': { type: :object, additionalProperties: true },
          binary: { type: :string, format: :binary, description: 'MODS XML to apply to the Work' }
        }
      }

      response '200', 'work updated' do
        let(:work) { WorkCreator.call(parent_id: collection.noid) }
        let(:id)   { work.noid }
        let(:body) { { 'metadata[title]' => 'Updated' } }
        schema '$ref' => '#/components/schemas/Work'
        run_test!
      end
    end

    delete 'Destroy a work' do
      tags 'Works'

      response '200', 'work destroyed' do
        let(:work) { WorkCreator.call(parent_id: collection.noid) }
        let(:id)   { work.noid }
        run_test!
      end
    end
  end

  path '/works/{id}/mods' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Work'

    get 'Retrieve MODS metadata for a work' do
      tags 'Works'
      produces 'application/xml', 'application/json'
      description 'Returns MODS XML by default; pass Accept: application/json for the JSON projection.'

      response '200', 'mods returned' do
        let(:work) { WorkCreator.call(parent_id: collection.noid) }
        let(:id)   { work.noid }
        let(:Accept) { 'application/xml' }
        run_test!
      end
    end
  end

  path '/works/{id}/files' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Work'

    get 'List files attached to a work' do
      tags 'Works'
      produces 'application/json'
      description 'Returns a flat array of file refs from non-descriptive FileSets attached to the Work.'

      response '200', 'files listed' do
        let(:work) { WorkCreator.call(parent_id: collection.noid) }
        let(:id)   { work.noid }
        schema '$ref' => '#/components/schemas/WorkBlobs'
        run_test!
      end
    end
  end
end
