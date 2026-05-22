# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'Collections', type: :request do
  let(:community) { CommunityCreator.call }

  after { Atlas.persister.wipe! }

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
        type:       :object,
        properties: { parent_id: { type: :string, description: 'NOID of the parent Community' } },
        required:   %w[parent_id]
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

      response '410', 'collection tombstoned' do
        let(:collection) do
          c = CollectionCreator.call(parent_id: community.noid)
          c.tombstoned = true
          Atlas.persister.save(resource: c)
        end
        let(:id) { collection.noid }
        schema '$ref' => '#/components/schemas/Collection'
        run_test!
      end
    end

    patch 'Update a collection' do
      tags 'Collections'
      consumes 'multipart/form-data'
      produces 'application/json'
      description <<~DESC
        Update descriptive metadata on a Collection. Either supply a
        `binary` MODS XML upload or `metadata[*]` form fields.

        Thumbnail-family URI writes have their own purpose-specific
        endpoint — see `PATCH /collections/{id}/thumbnails`.
      DESC
      parameter name: 'metadata[title]',         in: :formData, required: false
      parameter name: 'metadata[description]',   in: :formData, required: false
      parameter name: :binary,                   in: :formData, required: false
      multipart_request_body(
        {
          'metadata[title]':       { type: :string },
          'metadata[description]': { type: :string },
          binary:                  { type: :string, format: :binary, description: 'MODS XML to apply to the Collection' }
        }
      )

      response '200', 'collection updated' do
        let(:collection)         { CollectionCreator.call(parent_id: community.noid) }
        let(:id)                 { collection.noid }
        let(:'metadata[title]')  { 'Updated' }
        schema '$ref' => '#/components/schemas/Collection'
        run_test!
      end
    end

    delete 'Destroy a collection' do
      tags 'Collections'

      response '204', 'collection destroyed' do
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

      response '410', 'collection tombstoned' do
        let(:collection) do
          c = CollectionCreator.call(parent_id: community.noid)
          c.tombstoned = true
          Atlas.persister.save(resource: c)
        end
        let(:id) { collection.noid }
        schema '$ref' => '#/components/schemas/Collection'
        run_test!
      end
    end
  end

  path '/collections/{id}/ancestors' do
    parameter name: :id, in: :path, type: :string

    get 'List ancestors of a collection' do
      tags 'Collections'
      produces 'application/json'
      description 'Returns the ancestor chain as an array of [noid, type-name] pairs.'

      response '200', 'ancestors listed' do
        let(:collection) { CollectionCreator.call(parent_id: community.noid) }
        let(:id)         { collection.noid }
        schema '$ref' => '#/components/schemas/Lineage'
        run_test!
      end

      response '410', 'collection tombstoned' do
        let(:collection) do
          c = CollectionCreator.call(parent_id: community.noid)
          c.tombstoned = true
          Atlas.persister.save(resource: c)
        end
        let(:id) { collection.noid }
        schema '$ref' => '#/components/schemas/Collection'
        run_test!
      end
    end
  end

  path '/collections/{id}/thumbnails' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Collection'

    patch 'Attach thumbnail-family IIIF Delegate URIs to a collection' do
      tags 'Collections'
      consumes 'application/json'
      produces 'application/json'
      description <<~DESC
        Upserts one or more thumbnail-tier Delegates on the Collection
        (85px `thumbnail`, 170px `thumbnail_2x`, 500px `preview`). Missing
        keys are left untouched. Mirrors the Works endpoint of the same
        shape; collection-level thumbnails surface in the Cerberus
        browse UI.
      DESC
      parameter name: :body, in: :body, schema: {
        type:       :object,
        properties: {
          thumbnail:    { type: :string, description: 'IIIF URL for the 85px thumbnail tier' },
          thumbnail_2x: { type: :string, description: 'IIIF URL for the 170px retina thumbnail tier' },
          preview:      { type: :string, description: 'IIIF URL for the 500px hero preview tier' }
        }
      }

      response '200', 'all three thumbnail-family keys land in one PATCH' do
        let(:collection) { CollectionCreator.call(parent_id: community.noid) }
        let(:id) { collection.noid }
        let(:body) do
          {
            thumbnail:    'https://iiif.example/iiif/3/c.jp2/full/!85,85/0/default.jpg',
            thumbnail_2x: 'https://iiif.example/iiif/3/c.jp2/full/!170,170/0/default.jpg',
            preview:      'https://iiif.example/iiif/3/c.jp2/full/500,/0/default.jpg'
          }
        end
        schema '$ref' => '#/components/schemas/Collection'
        run_test! do |response|
          json = JSON.parse(response.body).fetch('collection')
          expect(json['thumbnail']).to eq('https://iiif.example/iiif/3/c.jp2/full/!85,85/0/default.jpg')
          expect(json['thumbnail_2x']).to eq('https://iiif.example/iiif/3/c.jp2/full/!170,170/0/default.jpg')
          expect(json['preview']).to eq('https://iiif.example/iiif/3/c.jp2/full/500,/0/default.jpg')
        end
      end
    end
  end

  path '/collections/{id}/tombstone' do
    parameter name: :id, in: :path, type: :string

    post 'Tombstone a collection' do
      tags 'Collections'
      produces 'application/json'
      description 'Marks a Collection as tombstoned. Refuses with 422 if the collection has live (non-tombstoned) members.'

      response '200', 'collection tombstoned' do
        let(:collection) { CollectionCreator.call(parent_id: community.noid) }
        let(:id)         { collection.noid }
        schema '$ref' => '#/components/schemas/Collection'
        run_test!
      end

      response '422', 'collection has live members' do
        let(:collection) { CollectionCreator.call(parent_id: community.noid) }
        let(:id)         { collection.noid }
        before { WorkCreator.call(parent_id: collection.noid) }
        run_test!
      end
    end
  end

  path '/collections/{id}/restore' do
    parameter name: :id, in: :path, type: :string

    post 'Restore a tombstoned collection' do
      tags 'Collections'
      produces 'application/json'
      description 'Clears the tombstone flag on a Collection. Cerberus does not expose this — call from operator console.'

      response '200', 'collection restored' do
        let(:collection) do
          c = CollectionCreator.call(parent_id: community.noid)
          c.tombstoned = true
          Atlas.persister.save(resource: c)
        end
        let(:id) { collection.noid }
        schema '$ref' => '#/components/schemas/Collection'
        run_test!
      end
    end
  end
end
