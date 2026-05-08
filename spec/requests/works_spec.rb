# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'Works', type: :request do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }

  after { Atlas.persister.wipe! }

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
      description 'Either supply a `binary` MODS XML upload or `metadata[*]` form fields to merge in.'
      parameter name: 'metadata[title]',       in: :formData, required: false
      parameter name: 'metadata[description]', in: :formData, required: false
      parameter name: 'metadata[thumbnail]',   in: :formData, required: false
      parameter name: :binary,                 in: :formData, required: false
      multipart_request_body(
        {
          'metadata[title]':       { type: :string },
          'metadata[description]': { type: :string },
          'metadata[thumbnail]':   { type: :string },
          binary: { type: :string, format: :binary, description: 'MODS XML to apply to the Work' }
        }
      )

      response '200', 'work updated' do
        let(:work)              { WorkCreator.call(parent_id: collection.noid) }
        let(:id)                { work.noid }
        let(:'metadata[title]') { 'Updated' }
        schema '$ref' => '#/components/schemas/Work'
        run_test!
      end
    end

    delete 'Destroy a work' do
      tags 'Works'

      response '204', 'work destroyed' do
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

  path '/works/{id}/tombstone' do
    parameter name: :id, in: :path, type: :string

    post 'Tombstone a work' do
      tags 'Works'
      produces 'application/json'
      description 'Marks a Work as tombstoned. Always succeeds; FileSets and Blobs ride along with the parent Work.'

      response '200', 'work tombstoned' do
        let(:work) { WorkCreator.call(parent_id: collection.noid) }
        let(:id)   { work.noid }
        schema '$ref' => '#/components/schemas/Work'
        run_test!
      end
    end
  end

  path '/works/{id}/restore' do
    parameter name: :id, in: :path, type: :string

    post 'Restore a tombstoned work' do
      tags 'Works'
      produces 'application/json'
      description 'Clears the tombstone flag on a Work. Cerberus does not expose this — call from operator console.'

      response '200', 'work restored' do
        let(:work) do
          w = WorkCreator.call(parent_id: collection.noid)
          w.tombstoned = true
          Atlas.persister.save(resource: w)
        end
        let(:id) { work.noid }
        schema '$ref' => '#/components/schemas/Work'
        run_test!
      end
    end
  end
end
