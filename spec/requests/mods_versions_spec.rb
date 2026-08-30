# frozen_string_literal: true

require 'rails_helper'

# Behavioral coverage for the MODS version-history endpoints. The rswag DSL
# in resources_spec.rb documents the shapes (and drives OpenAPI); this file
# exercises the moving parts the docs can't: actor correlation, version
# ordering, the seed-unattributed case, cross-type parity, auth gating, and
# the OCFL-count invariant.
#
# Note on version labels: they are opaque, sortable OCFL `vN` labels, NOT a
# 1-based MODS counter. A Blob's preservation envelope (properties.json,
# permissions.json) is written into the same OCFL object before the seed
# descMetadata.xml, so the first MODS version is typically v3, and each edit
# bumps to the next global vN. So these specs assert on ordering, counts, and
# labels read back from the response — never on hard-coded vN values.
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
  let(:guest_headers) { signed_auth_headers(guest.nuid) }

  # The NOID minter (Noid::Rails::Minter::Db) reads a counter row that the
  # per-example transaction rolls back, so every example re-mints the same
  # NOID sequence. OCFL storage (tmp/files) is only wiped before(:suite), so
  # without a per-example sweep a reused NOID's object accumulates versions
  # across examples and the per-example counts drift. Wipe up front to mirror
  # the suite-start cleanup at example scope.
  before { FileUtils.rm_rf(Rails.root.join('tmp/files')) }
  after { Atlas.persister.wipe! }

  # A second MODS fixture with content distinct from work-mods.xml, so two
  # edits produce two distinct digests (not a coalesced no-op).
  let(:other_fixture) { Rails.root.join('spec/fixtures/files/collection-mods.xml').to_s }

  # Drive the real HTTP write path so the OCFL version + correlated
  # AuditEvent are both produced exactly as production does it.
  def edit_mods(noid, route: 'works', fixture: mods_fixture)
    patch "/#{route}/#{noid}",
          params: { binary: Rack::Test::UploadedFile.new(fixture) }
    expect(response).to have_http_status(:ok)
  end

  def versions_for(noid)
    get "/resources/#{noid}/mods/versions"
    expect(response).to have_http_status(:ok)
    response.parsed_body['versions']
  end

  describe 'GET /resources/:id/mods/versions' do
    it 'correlates the editing actor to the version it produced' do
      work = WorkCreator.call(parent_id: collection.noid)
      edit_mods(work.noid)

      get "/resources/#{work.noid}/mods/versions"
      expect(response).to have_http_status(:ok)

      body = response.parsed_body
      expect(body['resource_id']).to eq(work.noid)
      # The newest version is the full-document replace just made; source 'mods'.
      expect(body['versions'].first).to include('actor_nuid' => editor_nuid, 'source' => 'mods')
    end

    it 'leaves a never-edited resource’s seed version unattributed' do
      # A Work fresh from WorkCreator has only the template seed and no `mods`
      # edit event, so attribution is null — not a phantom timestamp match.
      work = WorkCreator.call(parent_id: collection.noid)

      versions = versions_for(work.noid)
      expect(versions.length).to eq(1)
      expect(versions.first['actor_nuid']).to be_nil
      expect(versions.first['source']).to be_nil
    end

    it 'lists content-distinct versions newest-first' do
      work = WorkCreator.call(parent_id: collection.noid)
      edit_mods(work.noid)                          # work-mods.xml
      edit_mods(work.noid, fixture: other_fixture)  # distinct content -> distinct digest

      # parsed_body is a plain Array, not an AR relation; Rails/Pluck doesn't apply.
      labels = versions_for(work.noid).map { |v| v['version_id'] } # rubocop:disable Rails/Pluck
      # One seed + two content-distinct edits, descending by numeric vN.
      expect(labels.length).to eq(3)
      ordinals = labels.map { |l| l.delete_prefix('v').to_i }
      expect(ordinals).to eq(ordinals.sort.reverse)
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
        expect(versions_for(resource.noid).first)
          .to include('actor_nuid' => editor_nuid, 'source' => 'mods')
      end
    end

    it 'coalesces byte-identical consecutive revisions into one user-facing version' do
      work = WorkCreator.call(parent_id: collection.noid)
      edit_mods(work.noid) # work-mods.xml
      edit_mods(work.noid) # same bytes again -> a no-op OCFL revision

      reloaded = Work.find(work.noid)
      retained = Valkyrie.config.storage_adapter.find_versions(id: reloaded.mods_blob.latest_revision)

      listed = versions_for(work.noid)
      # OCFL faithfully keeps every revision; the listing collapses the
      # identical pair into one content state (seed + one edit).
      expect(retained.length).to eq(3)
      expect(listed.length).to eq(2)
      # Every listed version_id still resolves through the fetch endpoint.
      listed.each do |version|
        get "/resources/#{work.noid}/mods/versions/#{version['version_id']}"
        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe 'GET /resources/:id/mods/versions/:version_id' do
    it 'serves the raw historical XML for the requested version' do
      work = WorkCreator.call(parent_id: collection.noid)
      edit_mods(work.noid) # newest version = work-mods.xml fixture ("What's New")

      versions = versions_for(work.noid)
      newest   = versions.first['version_id'] # the edit
      seed     = versions.last['version_id']  # the template the Work was born with

      get "/resources/#{work.noid}/mods/versions/#{newest}"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("What's New")

      get "/resources/#{work.noid}/mods/versions/#{seed}"
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("What's New")
    end

    it 'is on the resource read gate, not an operator gate (a guest reads a public Work)' do
      work = WorkCreator.call(parent_id: collection.noid)
      work.publicize
      Atlas.persister.save(resource: work)
      seed = versions_for(work.noid).first['version_id']

      get "/resources/#{work.noid}/mods/versions/#{seed}", headers: guest_headers
      expect(response).to have_http_status(:ok)
    end

    it '404s for an unknown version' do
      work = WorkCreator.call(parent_id: collection.noid)
      get "/resources/#{work.noid}/mods/versions/v9999"
      expect(response).to have_http_status(:not_found)
    end
  end
end
