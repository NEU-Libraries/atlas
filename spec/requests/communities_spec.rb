# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'Communities', type: :request do
  after { Atlas.persister.wipe! }

  path '/communities' do
    get 'List communities' do
      tags 'Communities'
      produces 'application/json'
      description <<~DESC
        Lists every Community, one page at a time.
      DESC
      paginated

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
        it), otherwise `403`; a given-but-unresolvable one is `404`. A
        tombstoned parent refuses the create with `422 tombstoned_parent`,
        after the edit-rights check.

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

      response '422', 'the parent Community is tombstoned' do
        let(:parent) { CommunityCreator.call }
        let(:body)   { { parent_id: parent.noid } }
        before do
          parent.tombstone(by: '000000004')
          Atlas.persister.save(resource: parent)
        end
        run_test! do |response|
          expect(response.parsed_body['code']).to eq('tombstoned_parent')
          expect(parent.children.grep(Community)).to be_empty
        end
      end
    end
  end

  path '/communities/{id}' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Community'

    get 'Retrieve a community' do
      tags 'Communities'
      produces 'application/json'
      description <<~DESC
        Returns a Community's record: its metadata, its ancestors and its state.

        A tombstoned Community answers `410`: an admin or delegated admin gets the
        full record, and everyone else gets a stub. A purged NOID answers `410` with
        a stub that names the Community as purged, to every caller.
      DESC

      response '200', 'community found' do
        let(:community) { CommunityCreator.call }
        let(:id)        { community.noid }
        schema '$ref' => '#/components/schemas/Community'
        run_test!
      end

      tombstoned_record_responses(full: 'Community', withheld: 'CommunityTombstone', purged: true) do
        let(:id) { tombstoned_public_container!(Community).noid }
      end
    end
  end

  path '/communities/{id}/mods' do
    parameter name: :id, in: :path, type: :string

    get 'Retrieve MODS metadata for a community' do
      tags 'Communities'
      produces 'application/xml', 'application/json'
      description <<~DESC
        Returns the Community's descriptive metadata. Send `Accept: application/xml`
        for the MODS XML, which is the preservation copy, or `Accept:
        application/json` for the JSON access copy.

        A tombstoned Community's metadata answers `410` with the `Tombstoned` body
        to everyone but admins and delegated admins.
      DESC

      withheld_by_tombstone do
        let(:id) { tombstoned_public_container!(Community).noid }
      end

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
      description <<~DESC
        Returns the NOIDs of the Community's direct children, Collections and
        Communities. Fetch each one by its NOID.

        A tombstoned Community answers `410`: an admin or delegated admin gets the
        full record, and everyone else gets a stub.
      DESC

      response '200', 'children listed' do
        let(:community) { CommunityCreator.call }
        let(:id)        { community.noid }
        schema type: :array, items: { type: :string }
        run_test!
      end

      tombstoned_record_responses(full: 'Community', withheld: 'CommunityTombstone') do
        let(:id) { tombstoned_public_container!(Community).noid }
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
