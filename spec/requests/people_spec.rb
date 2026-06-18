# frozen_string_literal: true

require 'swagger_helper'

# Default request auth is a signed admin assertion (manage :all), so the happy
# paths exercise the write surface without extra setup; the :standard 403 case
# overrides Authorization to prove the :system/admin gate.
RSpec.describe 'People', type: :request do
  let(:community) { CommunityCreator.call }

  let!(:jane) { PersonCreator.call(nuid: '001234567', display_name: 'Jane Doe', orcid: '0000-0002-1825-0097') }

  after { Atlas.persister.wipe! }

  path '/people' do
    get 'List or batch-resolve people' do
      tags 'People'
      produces 'application/json'
      description <<~DESC
        Without params: a paginated list of all Persons. With `?nuids=a,b,c`:
        batch-resolve to the authoritative display_name (supersedes the SSO
        users directory's name), dropping unresolved nuids — `pagination` is
        omitted on the batch path.
      DESC
      parameter name: :nuids, in: :query, type: :string, required: false,
                description: 'Comma-separated NUIDs to batch-resolve'

      response '200', 'paginated list' do
        let(:nuids) { nil }
        schema '$ref' => '#/components/schemas/PeopleIndex'
        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body['people'].map { |p| p['person']['nuid'] }).to include('001234567')
          expect(body['pagination']).to be_present
        end
      end

      response '200', 'batch resolve by nuids (no pagination)' do
        let!(:bob) { PersonCreator.call(nuid: '007654321', display_name: 'Bob Roe') }
        let(:nuids) { '001234567,007654321,000000000' }
        schema '$ref' => '#/components/schemas/PeopleIndex'
        run_test! do |response|
          body = JSON.parse(response.body)
          names = body['people'].map { |p| p['person']['display_name'] }
          # No truncation despite pagination — page size follows match count.
          expect(names).to contain_exactly('Jane Doe', 'Bob Roe')
        end
      end
    end

    post 'Create a person (system/admin)' do
      tags 'People'
      consumes 'application/json'
      produces 'application/json'
      description <<~DESC
        Creates a neutral curatorial identity. One Person per NUID — a duplicate
        NUID is a 409. System/admin only; a non-privileged caller receives 403.
      DESC
      parameter name: :Authorization, in: :header, type: :string, required: false
      parameter name: :body, in: :body, schema: {
        type:       :object,
        properties: {
          nuid:         { type: :string },
          display_name: { type: :string },
          bio:          { type: :string },
          orcid:        { type: :string },
          title:        { type: :string }
        },
        required:   %w[nuid display_name]
      }

      response '201', 'created' do
        let(:Authorization) { "Bearer #{DefaultAuthHeaders.admin_assertion}" }
        let(:body) { { nuid: '009998888', display_name: 'New Person', title: 'Professor' } }
        schema '$ref' => '#/components/schemas/Person'
        run_test! do |response|
          person = JSON.parse(response.body)['person']
          expect(person).to include('nuid' => '009998888', 'display_name' => 'New Person', 'title' => 'Professor')
          # Create emits a structural audit row for the Person.
          expect(AuditEvent.where(action: 'create', resource_type: 'Person')).to exist
        end
      end

      response '409', 'duplicate nuid' do
        let(:Authorization) { "Bearer #{DefaultAuthHeaders.admin_assertion}" }
        let(:body) { { nuid: '001234567', display_name: 'Dupe' } }
        run_test! do |response|
          expect(JSON.parse(response.body)['code']).to eq('duplicate_nuid')
        end
      end

      response '403', 'non-system/admin caller is rejected' do
        let!(:librarian) do
          User.create!(email: 'lib@example.edu', password: SecureRandom.hex(16),
                       nuid: '005550000', role: :standard)
        end
        let(:Authorization) { "Bearer #{DefaultAuthHeaders.assertion_for('005550000')}" }
        let(:body) { { nuid: '004443333', display_name: 'Nope' } }
        run_test!
      end
    end
  end

  path '/people/{nuid}' do
    parameter name: :nuid, in: :path, type: :string, description: 'NUID of the person'

    get 'Fetch a person by NUID' do
      tags 'People'
      produces 'application/json'

      response '200', 'person found' do
        let(:nuid) { '001234567' }
        schema '$ref' => '#/components/schemas/Person'
        run_test! do |response|
          expect(JSON.parse(response.body)['person']['display_name']).to eq('Jane Doe')
        end
      end

      response '404', 'unknown nuid' do
        let(:nuid) { '000000000' }
        run_test!
      end
    end

    patch 'Edit authority fields (system/admin)' do
      tags 'People'
      consumes 'application/json'
      produces 'application/json'
      description 'Librarian edits to display_name/bio/orcid/title. NUID is immutable and not patchable.'
      parameter name: :body, in: :body, schema: {
        type:       :object,
        properties: {
          display_name: { type: :string },
          bio:          { type: :string },
          orcid:        { type: :string },
          title:        { type: :string }
        }
      }

      response '200', 'updated' do
        let(:nuid) { '001234567' }
        let(:body) { { display_name: 'Jane A. Doe', bio: 'Researcher' } }
        schema '$ref' => '#/components/schemas/Person'
        run_test! do |response|
          person = JSON.parse(response.body)['person']
          expect(person).to include('display_name' => 'Jane A. Doe', 'bio' => 'Researcher')
        end
      end

      response '404', 'unknown nuid' do
        let(:nuid) { '000000000' }
        let(:body) { { display_name: 'X' } }
        run_test!
      end
    end
  end

  path '/people/{nuid}/affiliations' do
    parameter name: :nuid, in: :path, type: :string

    post 'Add a community affiliation (audited, system/admin)' do
      tags 'People'
      consumes 'application/json'
      produces 'application/json'
      description 'Idempotent. Emits an add_affiliation audit event.'
      parameter name: :body, in: :body, schema: {
        type:       :object,
        properties: { community_id: { type: :string, description: 'NOID of the community' } },
        required:   %w[community_id]
      }

      response '200', 'affiliation added' do
        let(:nuid) { '001234567' }
        let(:body) { { community_id: community.noid } }
        schema '$ref' => '#/components/schemas/Person'
        run_test! do |response|
          expect(JSON.parse(response.body)['person']['affiliated_community_ids']).to eq([community.noid])
          expect(AuditEvent.where(action: 'add_affiliation', resource_id: jane.id.to_s)).to exist
        end
      end

      response '422', 'unknown community' do
        let(:nuid) { '001234567' }
        let(:body) { { community_id: 'does-not-exist' } }
        run_test! do |response|
          expect(JSON.parse(response.body)['code']).to eq('unknown_community')
        end
      end
    end
  end

  path '/people/{nuid}/affiliations/{community_id}' do
    parameter name: :nuid, in: :path, type: :string
    parameter name: :community_id, in: :path, type: :string

    delete 'Remove a community affiliation (audited, system/admin)' do
      tags 'People'
      produces 'application/json'
      description 'Tolerant — removing an absent affiliation is a no-op. Emits a remove_affiliation audit event.'

      response '200', 'affiliation removed' do
        let(:nuid) { '001234567' }
        let(:community_id) { community.noid }
        before do
          jane.affiliated_community_ids = [community.id]
          Atlas.persister.save(resource: jane)
        end
        schema '$ref' => '#/components/schemas/Person'
        run_test! do |response|
          expect(JSON.parse(response.body)['person']['affiliated_community_ids']).to eq([])
        end
      end
    end
  end
end
