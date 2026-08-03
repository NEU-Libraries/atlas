# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'Files (Blobs)', type: :request do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }
  let(:fixture)    { Rails.root.join('spec/fixtures/files/example.bin') }
  let!(:guest) do
    User.find_by(role: :guest) ||
      User.create!(email: 'guest@example.com', password: SecureRandom.hex(16), role: :guest)
  end

  after { Atlas.persister.wipe! }

  path '/files' do
    get 'List files' do
      tags 'Files'
      produces 'application/json'

      response '200', 'files listed' do
        schema '$ref' => '#/components/schemas/BlobsIndex'
        run_test!
      end
    end

    post 'Upload a file' do
      tags 'Files'
      consumes 'multipart/form-data'
      produces 'application/json'
      description <<~DESC
        Uploads a binary as a Blob attached to a Work.

        Idempotent on the optional `Idempotency-Key` header: a repeat
        request from the same caller with the same key returns the
        originally-created Blob without re-uploading. 410 + tombstone
        payload if the underlying Blob has been tombstoned.
      DESC
      parameter name: :work_id,           in: :formData, required: true
      parameter name: :original_filename, in: :formData, required: false
      parameter name: :expected_digest,   in: :formData, required: false
      parameter name: :binary,            in: :formData, required: true
      parameter name: :'Idempotency-Key', in: :header, type: :string, required: false,
                description: 'Client-supplied UUID; repeats return the existing resource.'
      multipart_request_body(
        {
          work_id:           { type: :string, description: 'NOID of the parent Work' },
          original_filename: { type: :string },
          expected_digest:   { type:        :string,
                               description: 'Optional verify-on-ingest checksum, "<algorithm>:<hexvalue>" ' \
                                            '(sha512/sha256/sha1/md5). Rejected 422 if the bytes do not match.' },
          binary:            { type: :string, format: :binary, description: 'File bytes to upload' }
        },
        required: %i[work_id binary]
      )

      response '200', 'file uploaded' do
        let(:work_id)           { work.noid }
        let(:original_filename) { 'example.bin' }
        let(:expected_digest)   { nil }
        let(:binary)            { Rack::Test::UploadedFile.new(fixture) }
        let(:'Idempotency-Key') { nil }
        schema '$ref' => '#/components/schemas/Blob'
        run_test! do |response|
          expect(JSON.parse(response.body).dig('blob', 'digest')).to match(/\Asha512:[0-9a-f]+\z/)
        end
      end

      response '200', 'verify-on-ingest passes when the digest matches' do
        let(:work_id)           { work.noid }
        let(:original_filename) { 'example.bin' }
        let(:expected_digest)   { "sha256:#{Digest::SHA256.file(fixture).hexdigest}" }
        let(:binary)            { Rack::Test::UploadedFile.new(fixture) }
        let(:'Idempotency-Key') { nil }
        schema '$ref' => '#/components/schemas/Blob'
        run_test!
      end

      response '422', 'verify-on-ingest rejects a digest mismatch (nothing persisted)' do
        let(:work_id)           { work.noid }
        let(:original_filename) { 'example.bin' }
        let(:expected_digest)   { 'sha256:0000000000000000000000000000000000000000000000000000000000000000' }
        let(:binary)            { Rack::Test::UploadedFile.new(fixture) }
        let(:'Idempotency-Key') { nil }
        run_test! do |response|
          expect(JSON.parse(response.body)['error']).to eq('fixity_mismatch')
          # No content Blob landed (the Work's descriptive-metadata Blob is unrelated setup).
          expect(Atlas.query.find_all_of_model(model: Blob).to_a.reject(&:metadata?)).to be_empty
        end
      end

      response '200', 'idempotent replay returns existing blob' do
        let(:work_id)           { work.noid }
        let(:original_filename) { 'example.bin' }
        let(:binary)            { Rack::Test::UploadedFile.new(fixture) }
        let(:idempotency_key)   { SecureRandom.uuid }
        let(:'Idempotency-Key') { idempotency_key }
        let!(:existing) do
          b = BlobCreator.call(work_id: work.noid, original_filename: 'example.bin', path: fixture.to_s)
          IdempotencyKey.create!(user: User.find_by(nuid: '000000004'), key: idempotency_key,
                                 resource_type: 'Blob', resource_noid: b.noid)
          b
        end
        schema '$ref' => '#/components/schemas/Blob'
        run_test! do |response|
          expect(JSON.parse(response.body).dig('blob', 'id')).to eq(existing.noid)
        end
      end

      response '410', 'idempotent replay on a tombstoned blob' do
        let(:work_id)           { work.noid }
        let(:original_filename) { 'example.bin' }
        let(:binary)            { Rack::Test::UploadedFile.new(fixture) }
        let(:idempotency_key)   { SecureRandom.uuid }
        let(:'Idempotency-Key') { idempotency_key }
        let!(:existing) do
          b = BlobCreator.call(work_id: work.noid, original_filename: 'example.bin', path: fixture.to_s)
          b.tombstoned = true
          b = Atlas.persister.save(resource: b)
          IdempotencyKey.create!(user: User.find_by(nuid: '000000004'), key: idempotency_key,
                                 resource_type: 'Blob', resource_noid: b.noid)
          b
        end
        schema '$ref' => '#/components/schemas/Blob'
        run_test!
      end
    end
  end

  path '/files/{id}' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Blob'

    get 'Retrieve file metadata' do
      tags 'Files'
      produces 'application/json'

      response '200', 'file found' do
        let(:blob) { BlobCreator.call(work_id: work.noid, original_filename: 'example.bin', path: fixture.to_s) }
        let(:id)   { blob.noid }
        schema '$ref' => '#/components/schemas/Blob'
        run_test!
      end

      response '410', 'file tombstoned' do
        let(:blob) do
          b = BlobCreator.call(work_id: work.noid, original_filename: 'example.bin', path: fixture.to_s)
          b.tombstoned = true
          Atlas.persister.save(resource: b)
        end
        let(:id) { blob.noid }
        schema '$ref' => '#/components/schemas/Blob'
        run_test!
      end
    end

    patch 'Append a new revision to a file' do
      tags 'Files'
      consumes 'multipart/form-data'
      produces 'application/json'
      description <<~DESC
        Uber-basic versioning: posts a new binary, appends its file identifier
        to the Blob (NOID preserved, prior bytes retained by OCFL).

        `size`, `mime_type` and `digest` are re-derived from the new bytes, so a
        consumer can set Content-Length and serve Range requests from the
        response. `original_filename` and `label` describe the deposit and do
        not change — use a fresh upload for a different filename.

        Idempotent on the optional `Idempotency-Key` header: a double-submit of
        the replace form with the same key returns the existing Blob instead of
        minting a second OCFL version.
      DESC
      parameter name: :binary,          in: :formData, required: true
      parameter name: :expected_digest, in: :formData, required: false
      parameter name: :'Idempotency-Key', in: :header, type: :string, required: false,
                description: 'Client-supplied UUID; repeats return the existing resource without a new revision.'
      multipart_request_body(
        {
          binary:          { type: :string, format: :binary, description: 'New revision bytes' },
          expected_digest: { type:        :string,
                             description: 'Optional verify-on-ingest checksum, "<algorithm>:<hexvalue>". 422 on mismatch.' }
        },
        required: %i[binary]
      )

      response '200', 'revision appended' do
        let(:blob)            { BlobCreator.call(work_id: work.noid, original_filename: 'example.bin', path: fixture.to_s) }
        let(:id)              { blob.noid }
        let(:replacement)     { Rails.root.join('spec/fixtures/files/example.tif') }
        let(:binary)          { Rack::Test::UploadedFile.new(replacement) }
        let(:expected_digest) { nil }
        let(:'Idempotency-Key') { nil }
        schema '$ref' => '#/components/schemas/Blob'
        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body.dig('blob', 'digest')).to match(/\Asha512:[0-9a-f]+\z/)
          expect(body.dig('blob', 'size')).to eq(File.size(replacement))
          expect(body.dig('blob', 'mime_type')).to eq('image/tiff')
        end
      end

      response '404', 'file not found' do
        let(:id)                { 'doesnotexist' }
        let(:binary)            { Rack::Test::UploadedFile.new(fixture) }
        let(:expected_digest)   { nil }
        let(:'Idempotency-Key') { nil }
        run_test!
      end
    end

    delete 'Destroy a file' do
      tags 'Files'

      response '204', 'file destroyed' do
        let(:blob) { BlobCreator.call(work_id: work.noid, original_filename: 'example.bin', path: fixture.to_s) }
        let(:id)   { blob.noid }
        run_test!
      end
    end
  end

  path '/files/{id}/content' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Blob'

    get 'Stream file content bytes' do
      tags 'Files'
      produces 'application/octet-stream'
      description <<~DESC
        Streams the underlying bytes with attachment disposition; memory-safe
        for large files. Supports HTTP Range for seekable A/V playback:
        `Accept-Ranges: bytes` is always advertised, a single `Range:
        bytes=START-END` request is answered `206 Partial Content` with
        `Content-Range`, and a syntactically-valid but unsatisfiable range is
        rejected `416`. Multi-range is not supported; an absent or unparseable
        Range serves the full `200` body.
      DESC

      parameter name: 'Range', in: :header, type: :string, required: false,
                description: 'Optional single byte range, e.g. `bytes=0-1048575`. Triggers a 206 Partial Content response.'

      let(:blob)  { BlobCreator.call(work_id: work.noid, original_filename: 'example.bin', path: fixture.to_s) }
      let(:id)    { blob.noid }
      let(:Range) { nil }

      response '200', 'content streamed (whole body)' do
        run_test! do |response|
          expect(response.headers['Accept-Ranges']).to eq('bytes')
          expect(response.body.bytesize).to eq(File.size(fixture))
        end
      end

      response '206', 'partial content (byte range)' do
        let(:Range) { 'bytes=0-9' }
        run_test! do |response|
          total = File.size(fixture)
          expect(response.headers['Content-Range']).to eq("bytes 0-9/#{total}")
          expect(response.headers['Content-Length']).to eq('10')
          expect(response.headers['Accept-Ranges']).to eq('bytes')
          expect(response.body.bytesize).to eq(10)
          expect(response.body).to eq(File.binread(fixture)[0..9])
        end
      end

      response '416', 'range not satisfiable' do
        let(:Range) { 'bytes=200000-200010' }
        run_test! do |response|
          expect(response.headers['Content-Range']).to eq("bytes */#{File.size(fixture)}")
        end
      end
    end
  end

  path '/files/{id}/ancestry' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Blob'

    get 'Resolve a file to its parent FileSet and Work' do
      tags 'Files'
      produces 'application/json'
      description <<~DESC
        Resolves a content Blob to its parent FileSet and containing Work noids
        (`{ "file_set": "<noid>", "work": "<noid>" }`). The download path is
        keyed only by the blob id, so a consumer recording a download/stream
        impression against the containing Work resolves it here rather than
        threading the work noid through the download URL. Reads on the Blob
        floor. Unknown id → 404; either value is null when unresolvable (e.g.
        an orphan blob with no FileSet parent).
      DESC

      response '200', 'ancestry resolved' do
        let(:blob) { BlobCreator.call(work_id: work.noid, original_filename: 'example.bin', path: fixture.to_s) }
        let(:id)   { blob.noid }
        schema '$ref' => '#/components/schemas/BlobAncestry'
        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body['work']).to eq(work.noid)
          file_set = Blob.find(blob.noid).parent
          expect(body['file_set']).to eq(file_set.noid)
        end
      end

      response '404', 'unknown blob' do
        let(:id) { 'does-not-exist' }
        run_test!
      end
    end
  end

  # Helper: the OCFL version label (vN) of a Blob's seed content revision.
  def seed_version_label(blob)
    Blob.find(blob.noid).file_identifiers.first.to_s[%r{/(v\d+)/}, 1]
  end

  path '/files/{id}/versions' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Blob'

    get 'List binary version history for a file' do
      tags 'Files'
      produces 'application/json'
      description <<~DESC
        Reverse-chronological list of the Blob's retained content revisions —
        the counterpart to `GET /resources/{id}/mods/versions`. Each descriptor
        carries a contiguous `revision` ordinal (the primary label: revision 1
        is the seed, and it never skips), the raw OCFL `version_id`
        (secondary/debug — it can jump, e.g. `v1 → v4`, because
        preservation-envelope bumps consume OCFL versions), its file
        identifier, the fixity `digest`/`size` recorded at that version, and
        actor attribution correlated from the file audit log (`actor_nuid` etc.
        are null when no event matches, e.g. a back-loaded Blob).

        Admin-gated, like the MODS version list, because the descriptors expose
        edit attribution (the devolved-admin tier — :privileged role + the
        repository:admin group — can also reach this). Unknown id → 404.
      DESC

      response '200', 'versions listed (newest first)' do
        let(:blob) { BlobCreator.call(work_id: work.noid, original_filename: 'example.bin', path: fixture.to_s) }
        let(:id)   { blob.noid }
        schema '$ref' => '#/components/schemas/BlobVersions'
        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body['blob_id']).to eq(blob.noid)
          expect(body['versions'].first['revision']).to eq(1)
          expect(body['versions'].first['version_id']).to match(/\Av\d+\z/)
          expect(body['versions'].first['digest']).to match(/\Asha512:[0-9a-f]+\z/)
        end
      end

      response '404', 'unknown blob' do
        let(:id) { 'does-not-exist' }
        run_test!
      end
    end
  end

  # Plain (non-rswag) coverage of the devolved-admin tier's :read_versions
  # grant — kept separate from the schema-driven path block above since it
  # asserts role/group combinations, not response shape.
  describe 'GET /files/:id/versions — devolved-admin tier', type: :request do
    let(:blob) { BlobCreator.call(work_id: work.noid, original_filename: 'example.bin', path: fixture.to_s) }
    let!(:delegate) do
      User.create!(email: 'delegate-versions@example.invalid', password: SecureRandom.hex(16),
                   nuid: '000000042', name: 'Williams, Delegate', role: :privileged,
                   groups: [Permissions::ADMIN_GROUP])
    end
    let!(:staff_no_group) do
      User.create!(email: 'staff-no-group@example.invalid', password: SecureRandom.hex(16),
                   nuid: '000000043', name: 'Roe, Sam', role: :privileged,
                   groups: [Permissions::STAFF_EDIT_GROUP])
    end

    it 'permits the delegate (:privileged + ADMIN_GROUP)' do
      get "/files/#{blob.noid}/versions", headers: signed_auth_headers(delegate.nuid)
      expect(response).to have_http_status(:ok)
    end

    it 'denies :privileged-without-the-group with 403' do
      get "/files/#{blob.noid}/versions", headers: signed_auth_headers(staff_no_group.nuid)
      expect(response).to have_http_status(:forbidden)
    end

    it 'does not leak into the generic audit-history index (:read_versions != :read AuditEvent)' do
      get "/resources/#{work.noid}/history", headers: signed_auth_headers(delegate.nuid)
      expect(response).to have_http_status(:forbidden)
    end
  end

  path '/files/{id}/versions/{version_id}/content' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Blob'
    parameter name: :version_id, in: :path, type: :string, description: 'OCFL version label, e.g. v1'

    get 'Stream a prior version’s content bytes' do
      tags 'Files'
      produces 'application/octet-stream'
      description <<~DESC
        Streams the bytes of a retained version, pinned to its OCFL label.
        Mirrors `GET /files/{id}/content` (same memory-safe send_file path) but
        resolves through the version history, so only listed content revisions
        are addressable. Unknown id or version → 404.
      DESC

      response '200', 'version content streamed' do
        let(:blob)       { BlobCreator.call(work_id: work.noid, original_filename: 'example.bin', path: fixture.to_s) }
        let(:id)         { blob.noid }
        let(:version_id) { seed_version_label(blob) }
        run_test!
      end

      response '404', 'unknown version' do
        let(:blob)       { BlobCreator.call(work_id: work.noid, original_filename: 'example.bin', path: fixture.to_s) }
        let(:id)         { blob.noid }
        let(:version_id) { 'v9999' }
        run_test!
      end
    end
  end

  path '/files/{id}/rollback' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Blob'

    post 'Roll a file back to a prior version' do
      tags 'Files'
      consumes 'application/json'
      produces 'application/json'
      description <<~DESC
        Promote a prior version to current by appending its bytes again as a
        new revision (non-destructive — it becomes vN+1 with the bytes of vN),
        keeping the Blob NOID. OCFL dedups the identical content. Unknown id or
        version → 404.
      DESC
      parameter name: :body, in: :body, schema: {
        type:       :object,
        properties: { version_id: { type: :string, description: 'OCFL version label to reinstate, e.g. v1' } },
        required:   %w[version_id]
      }

      response '200', 'rolled back (new revision appended)' do
        let(:blob)    { BlobCreator.call(work_id: work.noid, original_filename: 'example.bin', path: fixture.to_s) }
        let(:id)      { blob.noid }
        let(:body)    { { version_id: seed_version_label(blob) } }
        schema '$ref' => '#/components/schemas/Blob'
        run_test! do |response|
          expect(JSON.parse(response.body).dig('blob', 'id')).to eq(blob.noid)
        end
      end

      response '404', 'unknown version' do
        let(:blob) { BlobCreator.call(work_id: work.noid, original_filename: 'example.bin', path: fixture.to_s) }
        let(:id)   { blob.noid }
        let(:body) { { version_id: 'v9999' } }
        run_test!
      end
    end
  end
end
