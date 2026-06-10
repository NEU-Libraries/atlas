# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'User directory', type: :request do
  def create_person(nuid:, name:, role: :standard)
    User.create!(
      email:    "#{nuid}@example.edu",
      password: SecureRandom.hex(16),
      nuid:     nuid,
      name:     name,
      role:     role
    )
  end

  let!(:jane)  { create_person(nuid: '001111111', name: 'Doe, Jane') }
  let!(:janet) { create_person(nuid: '002222222', name: 'Smith, Janet', role: :privileged) }
  # Same-name rows in the excluded tiers — must never surface.
  let!(:guest_jane)  { create_person(nuid: '003333333', name: 'Jane, Guest', role: :guest) }
  let!(:system_jane) { create_person(nuid: '004444444', name: 'Jane, System', role: :system) }

  path '/users' do
    get 'Search the user directory' do
      tags 'User'
      produces 'application/json'
      description <<~D
        Read-only user directory. Two modes, same response shape:

        - `?q=<fragment>` — typeahead search: case-insensitive match on
          name, prefix match on NUID. Capped at 10, ordered by name.
        - `?nuids=a,b,c` — batch resolve (up to 100): exact NUIDs to
          entries; unknown NUIDs are dropped.

        Rows with role `anonymous`, `guest`, or `system` are never
        returned. With neither parameter the list is empty. Entries carry
        `nuid` + `name` only — a directory, not a profile endpoint.
      D
      parameter name: :q, in: :query, type: :string, required: false,
                description: 'Name fragment (case-insensitive) or NUID prefix'
      parameter name: :nuids, in: :query, type: :string, required: false,
                description: 'Comma-separated NUIDs to resolve in one call'

      response '200', 'matching directory entries (typeahead)' do
        schema '$ref' => '#/components/schemas/UserDirectory'
        let(:q)     { 'jane' }
        let(:nuids) { nil }
        run_test! do |response|
          expect(response.parsed_body).to eq(
            [
              { 'nuid' => jane.nuid,  'name' => 'Doe, Jane' },
              { 'nuid' => janet.nuid, 'name' => 'Smith, Janet' }
            ]
          )
        end
      end

      response '200', 'resolved directory entries (batch)' do
        schema '$ref' => '#/components/schemas/UserDirectory'
        let(:q)     { nil }
        let(:nuids) { "#{janet.nuid},#{guest_jane.nuid},#{jane.nuid},no-such-nuid" }
        run_test! do |response|
          expect(response.parsed_body).to eq(
            [
              { 'nuid' => jane.nuid,  'name' => 'Doe, Jane' },
              { 'nuid' => janet.nuid, 'name' => 'Smith, Janet' }
            ]
          )
        end
      end
    end
  end

  path '/users/by_nuid/{nuid}' do
    get 'Resolve a NUID to a directory entry' do
      tags 'User'
      produces 'application/json'
      description <<~D
        Single NUID to `{ nuid, name }`. Unknown NUIDs and rows with role
        `anonymous`, `guest`, or `system` both read as absent (404).
      D
      parameter name: :nuid, in: :path, type: :string

      response '200', 'directory entry found' do
        schema '$ref' => '#/components/schemas/UserDirectoryEntry'
        let(:nuid) { jane.nuid }
        run_test! do |response|
          expect(response.parsed_body)
            .to eq('nuid' => jane.nuid, 'name' => 'Doe, Jane')
        end
      end

      response '404', 'unknown or excluded NUID' do
        let(:nuid) { 'no-such-nuid' }
        run_test!
      end
    end
  end

  # Behaviors the OpenAPI examples above don't pin down.
  describe 'directory behavior' do
    it 'matches a NUID prefix in q searches' do
      get '/users', params: { q: '0011' }
      expect(response.parsed_body).to eq([{ 'nuid' => jane.nuid, 'name' => 'Doe, Jane' }])
    end

    it 'escapes SQL LIKE metacharacters in q' do
      get '/users', params: { q: '%' }
      expect(response.parsed_body).to eq([])
    end

    it 'caps q searches at 10 entries, ordered by name' do
      12.times { |i| create_person(nuid: format('09%07d', i), name: format('Cap, %02d', i)) }
      get '/users', params: { q: 'cap' }
      names = response.parsed_body.pluck('name')
      expect(names).to eq((0..9).map { |i| format('Cap, %02d', i) })
    end

    it 'returns an empty list with neither q nor nuids' do
      get '/users'
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq([])
    end

    it '404s a single resolve of an excluded role' do
      get "/users/by_nuid/#{guest_jane.nuid}"
      expect(response).to have_http_status(:not_found)
    end

    it 'allows a standard (non-admin) caller' do
      get '/users', params:  { q: 'janet' },
                    headers: { 'Authorization' => 'Bearer test-cerberus-token',
                               'User'          => "NUID #{jane.nuid}" }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq([{ 'nuid' => janet.nuid, 'name' => 'Smith, Janet' }])
    end
  end
end
