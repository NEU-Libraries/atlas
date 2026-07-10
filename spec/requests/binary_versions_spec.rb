# frozen_string_literal: true

require 'rails_helper'

# Behavioral coverage for the binary version-read endpoints. The rswag DSL in
# blobs_spec.rb documents the shapes (and drives OpenAPI); this file exercises
# the moving parts the docs can't: actor correlation per revision, version
# ordering, byte-for-byte retrieval of a superseded version, non-destructive
# rollback, replace idempotency, and auth gating.
#
# Version labels are opaque, sortable OCFL `vN` labels (the Blob's preservation
# envelope occupies some of the object's versions), so these specs assert on
# ordering, counts, and labels read back from the response — never on hard-
# coded vN values.
RSpec.describe 'Binary version history endpoints', type: :request do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  # The default request-spec principal is admin (NUID 000000004), so the
  # add_file / replace_file AuditEvents are attributed to it — exactly what the
  # version list should correlate back.
  let(:editor_nuid) { '000000004' }

  # Two fixtures with distinct bytes, so a replace produces a genuinely new
  # content state we can tell apart on retrieval.
  let(:fixture_a) { Rails.root.join('spec/fixtures/files/example.bin') }
  let(:fixture_b) { Rails.root.join('spec/fixtures/files/example.png') }

  let!(:guest) do
    User.find_by(role: :guest) ||
      User.create!(email: 'guest@example.invalid', password: SecureRandom.hex(16),
                   nuid: '000000001', name: 'User, Guest', role: :guest)
  end
  let(:guest_headers) { signed_auth_headers(guest.nuid) }

  # OCFL storage (tmp/files) is only wiped before(:suite); the NOID minter
  # re-mints the same sequence each rolled-back example, so without a per-
  # example sweep a reused NOID's object accumulates versions across examples.
  before { FileUtils.rm_rf(Rails.root.join('tmp/files')) }
  after { Atlas.persister.wipe! }

  # Drive the real HTTP write path so the OCFL version AND the correlated
  # add_file / replace_file AuditEvents are produced exactly as production does.
  def create_blob(fixture: fixture_a, filename: 'example.bin')
    post '/files', params: { work_id: work.noid, original_filename: filename,
                             binary: Rack::Test::UploadedFile.new(fixture) }
    expect(response).to have_http_status(:ok)
    response.parsed_body['blob']['id']
  end

  def replace_blob(noid, fixture: fixture_b, key: nil)
    headers = key ? { 'Idempotency-Key' => key } : {}
    patch "/files/#{noid}", params: { binary: Rack::Test::UploadedFile.new(fixture) }, headers: headers
  end

  def versions_for(noid)
    get "/files/#{noid}/versions"
    expect(response).to have_http_status(:ok)
    response.parsed_body['versions']
  end

  describe 'GET /files/:id/versions' do
    it 'lists content revisions newest-first, each correlated to its writing actor' do
      noid = create_blob
      replace_blob(noid)
      expect(response).to have_http_status(:ok)

      versions = versions_for(noid)
      expect(versions.length).to eq(2) # seed + one replace

      ordinals = versions.map { |v| v['version_id'].delete_prefix('v').to_i }
      expect(ordinals).to eq(ordinals.sort.reverse)
      # Both the seed (add_file) and the replace (replace_file) attribute to the actor.
      expect(versions.pluck('actor_nuid')).to all(eq(editor_nuid))
      expect(versions.first['digest']).to match(/\Asha512:[0-9a-f]+\z/)
      expect(versions.first['file_identifier']).to include('ocfl://')
      expect(versions.first['size']).to be_positive
      expect(versions.first['original_filename']).to eq('example.bin')
    end

    it 'lists a single seed revision for a never-replaced file' do
      noid = create_blob
      versions = versions_for(noid)
      expect(versions.length).to eq(1)
      expect(versions.first['revision']).to eq(1)
      expect(versions.first['actor_nuid']).to eq(editor_nuid)
    end

    it 'labels revisions with a contiguous 1-based ordinal, seed first' do
      noid = create_blob
      replace_blob(noid)
      replace_blob(noid)

      versions = versions_for(noid)
      # The revision ordinal is contiguous newest-first (3, 2, 1) with the seed
      # always revision 1 — derived from position, so it never skips the way the
      # raw OCFL version_id can (envelope bumps consume OCFL versions).
      expect(versions.pluck('revision')).to eq([3, 2, 1])
      expect(versions.last['revision']).to eq(1)
      expect(versions.pluck('version_id')).to all(match(/\Av\d+\z/))
    end

    it 'is admin-gated (guest is forbidden)' do
      noid = create_blob
      get "/files/#{noid}/versions", headers: guest_headers
      expect(response).to have_http_status(:forbidden)
    end

    it '404s for an unknown blob' do
      get '/files/does-not-exist/versions'
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'GET /files/:id/versions/:version_id/content' do
    it 'streams the original bytes of a superseded version, byte-for-byte' do
      noid = create_blob(fixture: fixture_a)
      replace_blob(noid, fixture: fixture_b)

      versions = versions_for(noid)
      seed    = versions.last['version_id']
      current = versions.first['version_id']

      get "/files/#{noid}/versions/#{seed}/content"
      expect(response).to have_http_status(:ok)
      expect(response.body.b).to eq(File.binread(fixture_a))

      get "/files/#{noid}/versions/#{current}/content"
      expect(response).to have_http_status(:ok)
      expect(response.body.b).to eq(File.binread(fixture_b))
    end

    it 'is readable on the resource read floor (guest allowed)' do
      noid = create_blob
      seed = versions_for(noid).first['version_id']
      get "/files/#{noid}/versions/#{seed}/content", headers: guest_headers
      expect(response).to have_http_status(:ok)
    end

    it '404s for an unknown version' do
      noid = create_blob
      get "/files/#{noid}/versions/v9999/content"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST /files/:id/rollback' do
    it 'reinstates a prior version non-destructively (NOID stable, list grows by one)' do
      noid = create_blob(fixture: fixture_a)
      replace_blob(noid, fixture: fixture_b) # current is now fixture_b

      before_versions = versions_for(noid)
      seed = before_versions.last['version_id']

      post "/files/#{noid}/rollback", params: { version_id: seed }, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('blob', 'id')).to eq(noid)

      # The list grew by one and the new current content is the seed's bytes.
      after_versions = versions_for(noid)
      expect(after_versions.length).to eq(before_versions.length + 1)

      get "/files/#{noid}/content"
      expect(response.body.b).to eq(File.binread(fixture_a))
    end

    it '404s for an unknown version' do
      noid = create_blob
      post "/files/#{noid}/rollback", params: { version_id: 'v9999' }, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'PATCH /files/:id idempotency (adjacency A)' do
    it 'mints one new version for two replaces sharing an Idempotency-Key' do
      noid = create_blob
      key  = SecureRandom.uuid

      replace_blob(noid, fixture: fixture_b, key: key)
      expect(response).to have_http_status(:ok)
      after_first = versions_for(noid).length

      replace_blob(noid, fixture: fixture_b, key: key)
      expect(response).to have_http_status(:ok)
      expect(versions_for(noid).length).to eq(after_first)
    end
  end
end
