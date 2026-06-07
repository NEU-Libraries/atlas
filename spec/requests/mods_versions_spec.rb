# frozen_string_literal: true

require 'rails_helper'

# Behavioral coverage for the MODS version-history endpoints. The rswag DSL
# in resources_spec.rb documents the shapes (and drives OpenAPI); this file
# exercises the moving parts the docs can't: actor correlation, version
# ordering, the seed-unattributed case, cross-type parity, auth gating, and
# the OCFL-count invariant.
RSpec.describe 'MODS version history endpoints', type: :request do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }

  let(:mods_fixture) { Rails.root.join('spec/fixtures/files/work-mods.xml') }

  # The default request-spec auth principal is admin (NUID 000000004), so a
  # MODS PATCH stamps a `mods` AuditEvent attributed to that NUID, which is
  # exactly what the version list should correlate back.
  let(:editor_nuid) { '000000004' }

  let!(:guest) do
    User.find_by(role: :guest) ||
      User.create!(email: 'guest@example.invalid', password: SecureRandom.hex(16),
                   nuid: '000000001', name: 'User, Guest', role: :guest)
  end
  let(:guest_headers) do
    { 'Authorization' => 'Bearer test-cerberus-token', 'User' => "NUID #{guest.nuid}" }
  end

  after { Atlas.persister.wipe! }

  # Drive the real HTTP write path so the OCFL version + correlated
  # AuditEvent are both produced exactly as production does it.
  def edit_mods(noid, route: 'works')
    patch "/#{route}/#{noid}",
          params: { binary: Rack::Test::UploadedFile.new(mods_fixture) }
    expect(response).to have_http_status(:ok)
  end

  describe 'GET /resources/:id/mods/versions' do
    it 'correlates the editing actor to the version it produced' do
      work = WorkCreator.call(parent_id: collection.noid)
      edit_mods(work.noid)

      get "/resources/#{work.noid}/mods/versions"
      expect(response).to have_http_status(:ok)

      body = response.parsed_body
      expect(body['resource_id']).to eq(work.noid)

      edited = body['versions'].find { |v| v['version_id'] == 'v2' }
      expect(edited).to include(
        'actor_nuid' => editor_nuid,
        'source'     => 'mods'
      )
    end

    it 'leaves a never-edited resource’s seed version unattributed' do
      # A Work fresh from WorkCreator has only the template seed (v1) and no
      # `mods` edit event, so attribution is null — not a phantom match.
      work = WorkCreator.call(parent_id: collection.noid)

      get "/resources/#{work.noid}/mods/versions"
      versions = response.parsed_body['versions']
      expect(versions.map { |v| v['version_id'] }).to eq(%w[v1])
      expect(versions.first['actor_nuid']).to be_nil
      expect(versions.first['source']).to be_nil
    end

    it 'lists versions newest-first' do
      work = WorkCreator.call(parent_id: collection.noid)
      edit_mods(work.noid) # v2
      edit_mods(work.noid) # v3

      get "/resources/#{work.noid}/mods/versions"
      expect(response.parsed_body['versions'].map { |v| v['version_id'] }).to eq(%w[v3 v2 v1])
    end

    it 'returns an empty array for a resource with no MODS (or an unknown id)' do
      get '/resources/does-not-exist/mods/versions'
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['versions']).to eq([])
    end

    it 'is admin-gated like /history (guest is forbidden)' do
      work = WorkCreator.call(parent_id: collection.noid)
      get "/resources/#{work.noid}/mods/versions", headers: guest_headers
      expect(response).to have_http_status(:forbidden)
    end

    it 'covers Collections and Communities through the same route' do
      edit_mods(collection.noid, route: 'collections')
      edit_mods(community.noid,  route: 'communities')

      [collection, community].each do |resource|
        get "/resources/#{resource.noid}/mods/versions"
        edited = response.parsed_body['versions'].find { |v| v['version_id'] == 'v2' }
        expect(edited).to include('actor_nuid' => editor_nuid, 'source' => 'mods')
      end
    end

    it 'reports exactly the versions the OCFL adapter retains' do
      work = WorkCreator.call(parent_id: collection.noid)
      edit_mods(work.noid)
      edit_mods(work.noid)

      reloaded = Work.find(work.noid)
      stored   = Valkyrie.config.storage_adapter.find_versions(id: reloaded.mods_blob.latest_revision)

      get "/resources/#{work.noid}/mods/versions"
      expect(response.parsed_body['versions'].length)
        .to eq(stored.length)
        .and eq(reloaded.mods_blob.file_identifiers.count)
    end
  end

  describe 'GET /resources/:id/mods/versions/:version_id' do
    it 'serves the raw historical XML for the requested version' do
      work = WorkCreator.call(parent_id: collection.noid)
      edit_mods(work.noid) # v2 = work-mods.xml fixture ("What's New")

      # v2 is the edited fixture; v1 is the seed template — they differ.
      get "/resources/#{work.noid}/mods/versions/v2"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("What's New")

      get "/resources/#{work.noid}/mods/versions/v1"
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("What's New")
    end

    it 'is readable on the resource read floor (guest allowed)' do
      work = WorkCreator.call(parent_id: collection.noid)
      get "/resources/#{work.noid}/mods/versions/v1", headers: guest_headers
      expect(response).to have_http_status(:ok)
    end

    it '404s for an unknown version' do
      work = WorkCreator.call(parent_id: collection.noid)
      get "/resources/#{work.noid}/mods/versions/v99"
      expect(response).to have_http_status(:not_found)
    end
  end
end
