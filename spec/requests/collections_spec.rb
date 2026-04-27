# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'Collections', type: :request do
  let(:community) { CommunityCreator.call }

  after { Valkyrie.config.metadata_adapter.persister.wipe! }

  path '/collections' do
    get 'List collections' do
      tags 'Collections'
      produces 'application/json'

      response '200', 'collections listed' do
        before { 2.times { CollectionCreator.call(parent_id: community.noid) } }
        schema '$ref' => '#/components/schemas/CollectionsIndex'
        run_test!
      end
    end

    post 'Create a collection' do
      tags 'Collections'
      consumes 'application/json'
      produces 'application/json'
      description 'Creates a Collection as a child of the given Community.'
      parameter name: :body, in: :body, schema: {
        type: :object,
        properties: { parent_id: { type: :string, description: 'NOID of the parent Community' } },
        required: %w[parent_id]
      }

      response '200', 'collection created' do
        let(:body) { { parent_id: community.noid } }
        schema '$ref' => '#/components/schemas/Collection'
        run_test!
      end
    end
  end

  path '/collections/{id}' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Collection'

    get 'Retrieve a collection' do
      tags 'Collections'
      produces 'application/json'

      response '200', 'collection found' do
        let(:collection) { CollectionCreator.call(parent_id: community.noid) }
        let(:id)         { collection.noid }
        schema '$ref' => '#/components/schemas/Collection'
        run_test!
      end
    end

    patch 'Update a collection' do
      tags 'Collections'
      consumes 'multipart/form-data'
      produces 'application/json'
      parameter name: :body, in: :body, schema: {
        type: :object,
        properties: {
          'metadata[title]':       { type: :string },
          'metadata[description]': { type: :string },
          'metadata[thumbnail]':   { type: :string },
          'metadata[permissions]': { type: :object, additionalProperties: true },
          binary: { type: :string, format: :binary, description: 'MODS XML to apply to the Collection' }
        }
      }

      response '200', 'collection updated' do
        let(:collection) { CollectionCreator.call(parent_id: community.noid) }
        let(:id)         { collection.noid }
        let(:body)       { { 'metadata[title]' => 'Updated' } }
        schema '$ref' => '#/components/schemas/Collection'
        run_test!
      end
    end

    delete 'Destroy a collection' do
      tags 'Collections'

      response '200', 'collection destroyed' do
        let(:collection) { CollectionCreator.call(parent_id: community.noid) }
        let(:id)         { collection.noid }
        run_test!
      end
    end
  end

  path '/collections/{id}/mods' do
    parameter name: :id, in: :path, type: :string

    get 'Retrieve MODS metadata for a collection' do
      tags 'Collections'
      produces 'application/xml', 'application/json'

      response '200', 'mods returned' do
        let(:collection) { CollectionCreator.call(parent_id: community.noid) }
        let(:id)         { collection.noid }
        let(:Accept)     { 'application/xml' }
        run_test!
      end
    end
  end

  path '/collections/{id}/children' do
    parameter name: :id, in: :path, type: :string

    get 'List child noids of a collection' do
      tags 'Collections'
      produces 'application/json'

      response '200', 'children listed' do
        let(:collection) { CollectionCreator.call(parent_id: community.noid) }
        let(:id)         { collection.noid }
        schema type: :array, items: { type: :string }
        run_test!
      end
    end
  end

  path '/collections/{id}/ancestors' do
    parameter name: :id, in: :path, type: :string

    get 'List ancestor noids of a collection' do
      tags 'Collections'
      produces 'application/json'

      response '200', 'ancestors listed' do
        let(:collection) { CollectionCreator.call(parent_id: community.noid) }
        let(:id)         { collection.noid }
        schema type: :array, items: { type: :string }
        run_test!
      end
    end
  end
end
