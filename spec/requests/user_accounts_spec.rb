# frozen_string_literal: true

require 'swagger_helper'

# Accounts sharing a NUID (a person's staff/student logins) + the preferred
# (default) account. rswag blocks document the shapes (and drive OpenAPI) under
# the default admin principal; the behavioral block asserts the self/admin/
# system authorization scope that the docs can't.
RSpec.describe 'User accounts', type: :request do
  let(:shared_nuid) { '000000055' }
  let!(:staff) do
    User.create!(email: 'p@northeastern.edu', nuid: shared_nuid, name: 'P',
                 password: SecureRandom.hex(16), role: :standard,
                 affiliation: 'staff', groups: ['g:staff'])
  end
  let!(:student) do
    User.create!(email: 'p@husky.neu.edu', nuid: shared_nuid, name: 'P',
                 password: SecureRandom.hex(16), role: :standard,
                 affiliation: 'student', groups: ['g:student'])
  end

  path '/users/by_nuid/{nuid}/accounts' do
    get 'List the accounts sharing a NUID' do
      tags 'User'
      produces 'application/json'
      description <<~D
        Every account sharing this NUID (a person's staff/student logins), each
        with email, affiliation label, role, stored group set, and the
        preferred flag. Discloses group sets, so it is limited to the person
        themselves, an admin, or the system principal; others receive 403.
      D
      parameter name: :nuid, in: :path, type: :string

      response '200', 'accounts listed' do
        schema '$ref' => '#/components/schemas/UserAccounts'
        let(:nuid) { shared_nuid }
        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body['nuid']).to eq(shared_nuid)
          expect(body['accounts'].pluck('email'))
            .to contain_exactly('p@northeastern.edu', 'p@husky.neu.edu')
          expect(body['accounts'].pluck('affiliation'))
            .to contain_exactly('staff', 'student')
        end
      end
    end
  end

  path '/users/by_nuid/{nuid}/preferred_account' do
    put 'Set the preferred (default) account for a NUID' do
      tags 'User'
      consumes 'application/json'
      produces 'application/json'
      description <<~D
        Set the person's default account (drives the login choice when no
        account is named). Same self/admin/system scope as the accounts list.
        An email that is not one of this NUID's accounts → 404.
      D
      parameter name: :nuid, in: :path, type: :string
      parameter name: :body, in: :body, schema: {
        type:       :object,
        properties: { email: { type: :string } },
        required:   %w[email]
      }

      response '200', 'preferred account set' do
        schema '$ref' => '#/components/schemas/ProvisionedUser'
        let(:nuid) { shared_nuid }
        let(:body) { { email: 'p@husky.neu.edu' } }
        run_test! do |response|
          expect(JSON.parse(response.body).dig('user', 'preferred')).to be(true)
          expect(student.reload.preferred).to be(true)
        end
      end

      response '404', 'email is not one of this NUID\'s accounts' do
        let(:nuid) { shared_nuid }
        let(:body) { { email: 'stranger@x.edu' } }
        run_test!
      end
    end
  end

  describe 'authorization scope', default_auth: false do
    it 'lets a person read their own accounts' do
      get "/users/by_nuid/#{shared_nuid}/accounts", headers: signed_auth_headers(shared_nuid)
      expect(response).to have_http_status(:ok)
    end

    it "forbids reading another NUID's accounts" do
      stranger = User.create!(email: 'x@x.edu', nuid: '000000077',
                              password: SecureRandom.hex(16), role: :standard)
      get "/users/by_nuid/#{shared_nuid}/accounts", headers: signed_auth_headers(stranger.nuid)
      expect(response).to have_http_status(:forbidden)
    end

    it 'lets a person set their own preferred account, one winner per NUID' do
      put "/users/by_nuid/#{shared_nuid}/preferred_account",
          params:  { email: 'p@husky.neu.edu' }.to_json,
          headers: signed_auth_headers(shared_nuid).merge('Content-Type' => 'application/json')
      expect(response).to have_http_status(:ok)
      expect(student.reload.preferred).to be(true)
      expect(User.where(nuid: shared_nuid, preferred: true).count).to eq(1)
    end
  end
end
