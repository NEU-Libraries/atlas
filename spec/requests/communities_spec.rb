# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'Communities', type: :request do
  after { Valkyrie.config.metadata_adapter.persister.wipe! }

  path '/communities' do
    get 'List communities' do
      tags 'Communities'
      produces 'application/json'

      response '200', 'communities listed' do
        before { 2.times { CommunityCreator.call } }
        schema '$ref' => '#/components/schemas/CommunitiesIndex'
        run_test!
      end
    end

    post 'Create a community' do
      tags 'Communities'
      consumes 'application/json'
      produces 'application/json'
      description 'Creates a Community. `parent_id` is optional — top-level communities have no parent.'
      parameter name: :body, in: :body, schema: {
        type: :object,
        properties: { parent_id: { type: :string, nullable: true } }
      }

      response '200', 'community created' do
        let(:body) { {} }
        schema '$ref' => '#/components/schemas/Community'
        run_test!
      end
    end
  end

  path '/communities/{id}' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Community'

    get 'Retrieve a community' do
      tags 'Communities'
      produces 'application/json'

      response '200', 'community found' do
        let(:community) { CommunityCreator.call }
        let(:id)        { community.noid }
        schema '$ref' => '#/components/schemas/Community'
        run_test!
      end
    end

    patch 'Update a community' do
      tags 'Communities'
      consumes 'multipart/form-data'
      produces 'application/json'
      parameter name: :body, in: :body, schema: {
        type: :object,
        properties: {
          'metadata[title]':       { type: :string },
          'metadata[description]': { type: :string },
          'metadata[thumbnail]':   { type: :string },
          'metadata[permissions]': { type: :object, additionalProperties: true },
          binary: { type: :string, format: :binary, description: 'MODS XML to apply to the Community' }
        }
      }

      response '200', 'community updated' do
        let(:community) { CommunityCreator.call }
        let(:id)        { community.noid }
        let(:body)      { { 'metadata[title]' => 'Updated' } }
        schema '$ref' => '#/components/schemas/Community'
        run_test!
      end
    end

    delete 'Destroy a community' do
      tags 'Communities'

      response '200', 'community destroyed' do
        let(:community) { CommunityCreator.call }
        let(:id)        { community.noid }
        run_test!
      end
    end
  end

  path '/communities/{id}/mods' do
    parameter name: :id, in: :path, type: :string

    get 'Retrieve MODS metadata for a community' do
      tags 'Communities'
      produces 'application/xml', 'application/json'

      response '200', 'mods returned' do
        let(:community) { CommunityCreator.call }
        let(:id)        { community.noid }
        let(:Accept)    { 'application/xml' }
        run_test!
      end
    end
  end

  path '/communities/{id}/children' do
    parameter name: :id, in: :path, type: :string

    get 'List child noids of a community' do
      tags 'Communities'
      produces 'application/json'

      response '200', 'children listed' do
        let(:community) { CommunityCreator.call }
        let(:id)        { community.noid }
        schema type: :array, items: { type: :string }
        run_test!
      end
    end
  end

  path '/communities/{id}/ancestors' do
    parameter name: :id, in: :path, type: :string

    get 'List ancestor noids of a community' do
      tags 'Communities'
      produces 'application/json'

      response '200', 'ancestors listed' do
        let(:community) { CommunityCreator.call }
        let(:id)        { community.noid }
        schema type: :array, items: { type: :string }
        run_test!
      end
    end
  end
end
