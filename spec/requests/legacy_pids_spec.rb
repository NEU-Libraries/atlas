# frozen_string_literal: true

require 'swagger_helper'

# The lookup Cerberus redirects old v1 URLs through. The read matrix crosses
# its gate with every tier; this adds the system path, which the matrix has no
# tier for. See docs/legacy-pids.md.
RSpec.describe 'Legacy pids', type: :request do
  after { Atlas.persister.wipe! }

  let(:private_collection) { CollectionCreator.call(parent_id: CommunityCreator.call.noid) }

  def public_work_with_pid(pid)
    collection = CollectionCreator.call(parent_id: public_community!.noid)
    work = WorkCreator.call(parent_id: collection.noid, legacy_pid: pid)
    work.publicize
    Atlas.persister.save(resource: work)
  end

  path '/resources/legacy/{pid}' do
    parameter name: :pid, in: :path, type: :string, example: 'neu:1234',
              description: 'A v1 pid, `neu:` prefix included'

    get 'Find the resource a v1 pid became' do
      tags 'Resources'
      response_texts(
        '200' => 'The NOID and type of the resource that holds the pid.',
        '404' => 'No resource holds the pid, or the caller may not read the one that does.'
      )
      produces 'application/json'
      description <<~DESC
        Answers which Community, Collection or Work a v1 pid migrated to, so a
        client can redirect an old v1 URL to the new object.

        A tombstoned holder still answers, with `tombstoned: true`: the old URL
        should land on its tombstone page. A caller who may not read the holder
        gets the same `404` as an unknown pid, so the lookup never reveals the
        NOID of something the caller cannot see. The system token reads past the
        per-resource gate, so a client resolving on a visitor's behalf can use it.

        The answer is not cached: a repository reset reuses NOIDs.
      DESC

      response '200', 'the holder, for an admin' do
        let!(:work) { WorkCreator.call(parent_id: private_collection.noid, legacy_pid: 'neu:1234') }
        let(:pid)   { 'neu:1234' }
        schema '$ref' => '#/components/schemas/LegacyPidHolder'
        run_test! do |response|
          expect(response.parsed_body).to eq('resource' => { 'id' => work.noid, 'type' => 'Work', 'tombstoned' => false })
        end
      end

      response '200', 'a tombstoned holder, flagged' do
        let!(:community) { tombstoned!(CommunityCreator.call(legacy_pid: 'neu:1')) }
        let(:pid)        { 'neu:1' }
        schema '$ref' => '#/components/schemas/LegacyPidHolder'
        run_test! do |response|
          expect(response.parsed_body['resource']).to include('id' => community.noid, 'type' => 'Community',
                                                              'tombstoned' => true)
        end
      end

      response '200', 'a public holder, for a guest', default_auth: false do
        let!(:work) { public_work_with_pid('neu:1240') }
        let(:pid)   { 'neu:1240' }
        before { guest_caller! }
        schema '$ref' => '#/components/schemas/LegacyPidHolder'
        run_test! do |response|
          expect(response.parsed_body.dig('resource', 'id')).to eq(work.noid)
        end
      end

      response '404', 'a private holder, for a guest', default_auth: false do
        let(:pid) { 'neu:1241' }
        before do
          WorkCreator.call(parent_id: private_collection.noid, legacy_pid: 'neu:1241')
          guest_caller!
        end
        run_test! do |response|
          expect(response.body).to be_empty
        end
      end

      response '404', 'no resource holds the pid' do
        let(:pid) { 'neu:9999' }
        run_test!
      end
    end
  end

  describe 'on the system path' do
    let!(:system_user) do
      User.find_by(role: :system) ||
        User.create!(email: 'system@example.com', password: SecureRandom.hex(16), nuid: '000000000', role: :system)
    end

    before { allow(Rails.application.credentials).to receive(:system_token).and_return('test-system-token') }

    it 'answers a private holder, so Cerberus can redirect for any visitor', default_auth: false do
      collection = CollectionCreator.call(parent_id: private_collection.noid)
      collection = Collection.find(CollectionCreator.call(parent_id: collection.noid, legacy_pid: 'neu:77').noid)

      get '/resources/legacy/neu:77',
          headers: { 'Authorization' => 'Bearer test-system-token', 'User' => "NUID #{system_user.nuid}" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['resource']).to include('id' => collection.noid, 'type' => 'Collection')
    end
  end

  describe 'a value that is not a v1 pid' do
    it 'answers 404, as an unknown pid does' do
      get '/resources/legacy/1234'

      expect(response).to have_http_status(:not_found)
    end
  end
end
