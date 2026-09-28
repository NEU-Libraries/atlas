# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'Embargoes', type: :request do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let!(:system_user) do
    User.find_by(nuid: '000000000') ||
      User.create!(email: 'system@example.com', password: SecureRandom.hex(16), nuid: '000000000', role: :system)
  end
  let(:system_token) { 'test-system-token' }

  before { allow(Rails.application.credentials).to receive(:system_token).and_return(system_token) }
  after  { Atlas.persister.wipe! }

  def lapsed_work
    work = WorkCreator.call(parent_id: collection.noid)
    work.permissions = work.permissions.merge(embargo: 2.days.ago.to_date.iso8601)
    Atlas.persister.save(resource: work)
  end

  path '/embargoes/release' do
    post 'Record the embargoes that have lapsed (system-only)' do
      tags 'Resources'
      produces 'application/json'
      description <<~DESC
        Writes one `release_embargo` audit row for each Work whose embargo has
        lapsed and has none for that release date. The row is dated to the
        start of the release day in Eastern time, not to the call, so a late
        call does not misdate the history. Cerberus calls it nightly; Atlas
        runs no scheduler.

        Safe to repeat. A Work whose embargo was set after its own release
        moment gets no row. By default it looks back seven days, so a missed
        night catches up on the next; `since` (an ISO 8601 date) widens that.
        Returns the NOIDs that gained a row. Non-system, non-admin callers → 403.
      DESC
      security [{ BearerAuth: [] }]
      parameter name: :Authorization, in: :header, type: :string, required: false
      parameter name: :User, in: :header, type: :string, required: false,
                description: 'System principal, e.g. "NUID 000000000"'
      parameter name: :since, in: :query, schema: { type: :string, format: :date }, required: false,
                description: 'Earliest release date to consider. Defaults to seven days ago.'

      let(:Authorization) { "Bearer #{system_token}" }
      let(:User)          { "NUID #{system_user.nuid}" }
      let(:since)         { nil }

      response '200', 'lapsed embargoes recorded' do
        schema '$ref' => '#/components/schemas/EmbargoRelease'
        let!(:work) { lapsed_work }

        run_test! do |response|
          expect(response.parsed_body['released']).to eq([work.noid])
          row = AuditEvent.for_resource(work.id).find_by(action: 'release_embargo')
          expect(row).to have_attributes(actor_nuid: system_user.nuid, event_source: 'job')
        end
      end

      response '400', 'since is not an ISO 8601 date' do
        let(:since) { 'last tuesday' }
        run_test!
      end
    end
  end

  it 'refuses a standard user', default_auth: false do
    User.create!(email: 'std@example.invalid', password: SecureRandom.hex(16), nuid: '000000005', role: :standard)
    post '/embargoes/release', headers: signed_auth_headers('000000005')
    expect(response).to have_http_status(:forbidden)
  end
end
