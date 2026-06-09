# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'Communities', type: :request do
  after { Atlas.persister.wipe! }

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
      description <<~DESC
        Creates a Community. `parent_id` is optional — top-level
        communities have no parent. Optional `depositor` is the NUID to
        stamp as the intellectual owner (mirrors the same surface on
        Collection/Work creates).
      DESC
      parameter name: :body, in: :body, schema: {
        type:       :object,
        properties: {
          parent_id: { type: :string, nullable: true },
          depositor: { type: :string, description: 'NUID to stamp as the Community depositor (optional)' }
        }
      }

      response '200', 'community created' do
        let(:body) { {} }
        schema '$ref' => '#/components/schemas/Community'
        run_test!
      end

      response '200', 'create with explicit depositor stamps the resource' do
        let(:body) { { depositor: '900000001' } }
        schema '$ref' => '#/components/schemas/Community'
        run_test! do |response|
          json = JSON.parse(response.body).fetch('community')
          expect(json['depositor']).to eq('900000001')
        end
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

      response '410', 'community tombstoned' do
        let(:community) do
          c = CommunityCreator.call
          c.tombstoned = true
          Atlas.persister.save(resource: c)
        end
        let(:id) { community.noid }
        schema '$ref' => '#/components/schemas/Community'
        run_test!
      end
    end

    patch 'Update a community' do
      tags 'Communities'
      consumes 'multipart/form-data'
      produces 'application/json'
      description <<~DESC
        Update a Community's descriptive metadata by supplying a `binary`
        MODS XML upload — the caller assembles the full document (descriptive
        merge logic lives in the client, not Atlas). `metadata[permissions]`
        adjusts the ACL. Any `metadata[title]` / `metadata[description]` keys
        are ignored.

        Thumbnail-family URI writes have their own purpose-specific
        endpoint — see `PATCH /communities/{id}/thumbnails`.
      DESC
      parameter name: :binary, in: :formData, required: false
      multipart_request_body(
        {
          binary: { type: :string, format: :binary, description: 'MODS XML to apply to the Community' }
        }
      )

      response '200', 'community updated' do
        let(:community) { CommunityCreator.call }
        let(:id)        { community.noid }
        let(:binary)    { Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/work-mods.xml')) }
        schema '$ref' => '#/components/schemas/Community'
        run_test!
      end
    end

    delete 'Destroy a community' do
      tags 'Communities'

      response '204', 'community destroyed' do
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

      response '410', 'community tombstoned' do
        let(:community) do
          c = CommunityCreator.call
          c.tombstoned = true
          Atlas.persister.save(resource: c)
        end
        let(:id) { community.noid }
        schema '$ref' => '#/components/schemas/Community'
        run_test!
      end
    end
  end

  path '/communities/{id}/ancestors' do
    parameter name: :id, in: :path, type: :string

    get 'List ancestors of a community' do
      tags 'Communities'
      produces 'application/json'
      description 'Returns the ancestor chain as an array of [noid, type-name] pairs.'

      response '200', 'ancestors listed' do
        let(:community) { CommunityCreator.call }
        let(:id)        { community.noid }
        schema '$ref' => '#/components/schemas/Lineage'
        run_test!
      end

      response '410', 'community tombstoned' do
        let(:community) do
          c = CommunityCreator.call
          c.tombstoned = true
          Atlas.persister.save(resource: c)
        end
        let(:id) { community.noid }
        schema '$ref' => '#/components/schemas/Community'
        run_test!
      end
    end
  end

  path '/communities/{id}/thumbnails' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Community'

    patch 'Attach thumbnail-family IIIF Delegate URIs to a community' do
      tags 'Communities'
      consumes 'application/json'
      produces 'application/json'
      description <<~DESC
        Upserts one or more thumbnail-tier Delegates on the Community
        (85px `thumbnail`, 170px `thumbnail_2x`, 500px `preview`). Missing
        keys are left untouched. Mirrors the Works endpoint of the same
        shape; community-level thumbnails surface in the Cerberus
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
        let(:community) { CommunityCreator.call }
        let(:id) { community.noid }
        let(:body) do
          {
            thumbnail:    'https://iiif.example/iiif/3/m.jp2/full/!85,85/0/default.jpg',
            thumbnail_2x: 'https://iiif.example/iiif/3/m.jp2/full/!170,170/0/default.jpg',
            preview:      'https://iiif.example/iiif/3/m.jp2/full/500,/0/default.jpg'
          }
        end
        schema '$ref' => '#/components/schemas/Community'
        run_test! do |response|
          json = JSON.parse(response.body).fetch('community')
          expect(json['thumbnail']).to eq('https://iiif.example/iiif/3/m.jp2/full/!85,85/0/default.jpg')
          expect(json['thumbnail_2x']).to eq('https://iiif.example/iiif/3/m.jp2/full/!170,170/0/default.jpg')
          expect(json['preview']).to eq('https://iiif.example/iiif/3/m.jp2/full/500,/0/default.jpg')
        end
      end
    end
  end

  path '/communities/{id}/parent' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Community to move'

    patch 'Re-parent a community' do
      tags 'Communities'
      consumes 'application/json'
      produces 'application/json'
      description <<~DESC
        Moves a Community under a different parent Community, or to the top of
        the tree (omit `parent_id` or pass null). Re-projects the moved
        subtree's descendant collections and sub-communities so their cached
        ancestry stays correct; Works are never touched. Rejects cycles, bad
        parent types, and tombstoned node/parent with a 422.
      DESC
      parameter name: :body, in: :body, schema: {
        type:       :object,
        properties: { parent_id: { type: :string, nullable: true, description: 'NOID of the new parent Community, or null for top-level' } }
      }

      response '200', 'community moved under another community' do
        let(:root)      { CommunityCreator.call }
        let(:new_root)  { CommunityCreator.call }
        let(:community) { CommunityCreator.call(parent_id: root.noid) }
        let(:id)        { community.noid }
        let(:body)      { { parent_id: new_root.noid } }
        schema '$ref' => '#/components/schemas/Community'
        run_test! do |response|
          ancestors = JSON.parse(response.body).dig('community', 'ancestors')
          expect(ancestors.map(&:first)).to include(new_root.noid)
        end
      end

      response '200', 'community moved to the top of the tree (null parent)' do
        let(:root)      { CommunityCreator.call }
        let(:community) { CommunityCreator.call(parent_id: root.noid) }
        let(:id)        { community.noid }
        let(:body)      { { parent_id: nil } }
        schema '$ref' => '#/components/schemas/Community'
        run_test! do |response|
          expect(JSON.parse(response.body).dig('community', 'ancestors')).to eq([])
        end
      end

      response '422', 'rejects an invalid parent type' do
        let(:root)       { CommunityCreator.call }
        let(:collection) { CollectionCreator.call(parent_id: root.noid) }
        let(:community)  { CommunityCreator.call(parent_id: root.noid) }
        let(:id)         { community.noid }
        let(:body)       { { parent_id: collection.noid } }
        run_test! do |response|
          expect(JSON.parse(response.body)['error']).to eq('invalid_parent_type')
        end
      end
    end
  end

  path '/communities/{id}/tombstone' do
    parameter name: :id, in: :path, type: :string

    post 'Tombstone a community' do
      tags 'Communities'
      produces 'application/json'
      description 'Marks a Community as tombstoned. Refuses with 422 if the community has live (non-tombstoned) members.'

      response '200', 'community tombstoned' do
        let(:community) { CommunityCreator.call }
        let(:id)        { community.noid }
        schema '$ref' => '#/components/schemas/Community'
        run_test!
      end

      response '422', 'community has live members' do
        let(:community) { CommunityCreator.call }
        let(:id)        { community.noid }
        before { CollectionCreator.call(parent_id: community.noid) }
        run_test!
      end
    end
  end

  path '/communities/{id}/restore' do
    parameter name: :id, in: :path, type: :string

    post 'Restore a tombstoned community' do
      tags 'Communities'
      produces 'application/json'
      description 'Clears the tombstone flag on a Community. Cerberus does not expose this — call from operator console.'

      response '200', 'community restored' do
        let(:community) do
          c = CommunityCreator.call
          c.tombstoned = true
          Atlas.persister.save(resource: c)
        end
        let(:id) { community.noid }
        schema '$ref' => '#/components/schemas/Community'
        run_test!
      end
    end
  end

  # Gap C regression — see collections_spec / permissions_spec for the
  # full rationale.
  describe 'PATCH /communities/:id with ACL-only metadata preserves provenance' do
    it 'leaves depositor/proxy_uploader intact when metadata[permissions] omits them' do
      community = CommunityCreator.call(
        proxy_uploader: '000000002',
        depositor:      '900000001',
        actor_nuid:     '000000002'
      )
      expect(community.depositor).to      eq('900000001')
      expect(community.proxy_uploader).to eq('000000002')

      patch "/communities/#{community.noid}",
            params: { metadata: { permissions: { read: ['public'], edit: [], edit_users: [] } } }

      expect(response).to have_http_status(:ok)
      reloaded = Community.find(community.noid)
      expect(reloaded.depositor).to      eq('900000001')
      expect(reloaded.proxy_uploader).to eq('000000002')
      expect(reloaded.read_groups.to_a).to eq(['public'])
    end
  end
end
