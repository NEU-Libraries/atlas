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
        communities have no parent, and are the one create Atlas allows
        without a container. When `parent_id` IS given the caller must hold
        edit rights on that Community (Grouper edit grant, or ownership of
        it), otherwise `403`; a given-but-unresolvable one is `404`.

        Optional `depositor` is the NUID to stamp as the intellectual
        owner (mirrors the same surface on Collection/Work creates).
      DESC
      parameter name: :body, in: :body, schema: {
        type:       :object,
        properties: {
          parent_id: { type: :string, nullable: true },
          depositor: { type: :string, description: 'NUID to stamp as the Community depositor (optional)' }
        }
      }
      parameter name: :Authorization, in: :header, type: :string, required: false

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

      response '403', 'caller holds no edit rights on the parent Community' do
        let!(:outsider) do
          User.create!(email: 'outsider-comm@example.invalid', password: SecureRandom.hex(16),
                       nuid: '009999996', name: 'Outsider, Ola', role: :standard,
                       groups: ['northeastern:drs:library:dsg_students'])
        end
        let(:parent)        { CommunityCreator.call }
        let(:body)          { { parent_id: parent.noid } }
        let(:Authorization) { "Bearer #{DefaultAuthHeaders.assertion_for('009999996')}" }
        run_test!
      end

      response '404', 'parent_id given but unresolvable' do
        let(:body) { { parent_id: 'nope404' } }
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

  # An ACL-only metadata PATCH must preserve provenance — see collections_spec
  # / permissions_spec for the full rationale.
  describe 'PATCH /communities/:id with ACL-only metadata preserves provenance' do
    it 'leaves depositor/proxy_uploader intact when metadata[permissions] omits them' do
      community = CommunityCreator.call(
        proxy_uploader: '000000002',
        depositor:      '900000001',
        actor_nuid:     '000000002'
      )
      expect(community.depositor).to      eq('900000001')
      expect(community.proxy_uploader).to eq('000000002')

      patch "/resources/#{community.noid}/permissions",
            params: { permissions: { read: ['public'], edit: [], edit_users: [] } }

      expect(response).to have_http_status(:ok)
      reloaded = Community.find(community.noid)
      expect(reloaded.depositor).to      eq('900000001')
      expect(reloaded.proxy_uploader).to eq('000000002')
      expect(reloaded.read_groups.to_a).to eq(['public'])
    end
  end
end
