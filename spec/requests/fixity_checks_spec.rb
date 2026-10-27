# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'Fixity checks', type: :request do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }
  let!(:system_user) do
    User.find_by(nuid: '000000000') ||
      User.create!(email: 'system@example.com', password: SecureRandom.hex(16), nuid: '000000000', role: :system)
  end
  let(:system_token) { 'test-system-token' }

  before { allow(Rails.application.credentials).to receive(:system_token).and_return(system_token) }
  after  { Atlas.persister.wipe! }

  def check_body(**overrides)
    { object: "urn:neu-drs:#{work.noid}", checked_at: '2026-10-27T03:12:09Z', version: 'v1',
      algorithm: 'sha512', files: 3, result: 'pass', findings: [], checker: 'ocfl-fixity-sweep 1.0' }
      .merge(overrides)
  end

  path '/fixity_checks' do
    post 'Record one fixity check result for an OCFL object (system and admin only)' do
      tags 'Resources'
      consumes 'application/json'
      produces 'application/json'
      description <<~DESC
        Records that a checker re-hashed one OCFL object: when, which version,
        with which algorithm, over how many files, the outcome and its
        findings. Atlas hashes nothing here; the checker did that work.

        The result is appended as one JSON line to the object's
        `logs/fixity.jsonl`, outside its versioned content, so recording a
        check never creates a version. That log is the record. The newest
        check per object is also kept as a derived row, projected onto the
        owning resource's Solr doc as `fixity_checked_at_dtsi` and
        `fixity_result_ssi`, and summarized by `GET /works/{id}/health_check`.

        A check older than the object's latest is logged but does not replace
        it, and `latest` is false. Posting the same check again adds no line
        and answers 200 instead of 201, so a retry is safe. A `fail` must
        carry at least one finding.

        The `:system` principal and admins only. Anyone else gets 403. An
        object no resource holds is a 404; an unknown version, or a resource
        with no OCFL object, is a 422 that writes nothing.
      DESC
      security [{ BearerAuth: [] }]
      parameter name: :Authorization, in: :header, type: :string, required: false
      parameter name: :User, in: :header, type: :string, required: false,
                description: 'System principal, e.g. "NUID 000000000"'
      parameter name: :body, in: :body, schema: {
        type:       :object,
        required:   %w[object checked_at version algorithm files result checker],
        properties: {
          object:     { type: :string, description: 'The OCFL inventory id, urn:neu-drs:<noid>' },
          checked_at: { type: :string, format: 'date-time', description: 'When the check ran. Kept to the second.' },
          version:    { type: :string, description: 'The object version checked, e.g. v3' },
          algorithm:  { type: :string, enum: FixityCheck::ALGORITHMS },
          files:      { type: :integer, minimum: 0, description: 'Files re-hashed' },
          result:     { type: :string, enum: FixityResult::RESULTS },
          findings:   { type: :array, maxItems: FixityCheck::MAX_FINDINGS, items: {
            type:       :object,
            required:   %w[code],
            properties: FixityCheck::FINDING_KEYS.to_h { |key| [key.to_sym, { type: :string }] }
          } },
          checker:    { type: :string, maxLength: FixityCheck::MAX_CHECKER, description: 'The tool that ran the check' }
        }
      }

      let(:Authorization) { "Bearer #{system_token}" }
      let(:User)          { "NUID #{system_user.nuid}" }

      response '201', 'check recorded' do
        let(:body) { check_body }
        schema '$ref' => '#/components/schemas/FixityCheck'
        run_test! do |response|
          expect(response.parsed_body['fixity_check'])
            .to include('resource_id' => work.noid, 'result' => 'pass', 'latest' => true, 'recorded_by' => '000000000')
          expect(FixityResult.find(work.noid).result).to eq('pass')
        end
      end

      response '200', 'the same check posted again; nothing added' do
        let(:body) { check_body }
        before { post '/fixity_checks', params: check_body.to_json, headers: system_headers }

        schema '$ref' => '#/components/schemas/FixityCheck'
        run_test! do
          lines = Valkyrie.config.storage_adapter.read_log(key: work.noid, name: FixityCheckRecorder::LOG_NAME)
          expect(lines.size).to eq(1)
        end
      end

      response '422', 'malformed, or names a version the object does not have; nothing written' do
        let(:body) { check_body(version: 'v99') }
        run_test! do |response|
          expect(response.parsed_body['error']).to eq('unknown_version')
          expect(FixityResult.where(object_key: work.noid)).not_to exist
        end
      end

      response '404', 'no resource holds the object' do
        let(:body) { check_body(object: 'urn:neu-drs:nosuchkey') }
        run_test!
      end

      response '403', 'not the system principal or an admin' do
        let(:Authorization) { "Bearer #{DefaultAuthHeaders.assertion_for(standard.nuid)}" }
        let(:User)          { nil }
        let(:standard) do
          User.create!(email: 'fixity-standard@example.invalid', password: SecureRandom.hex(16),
                       nuid: '000000071', name: 'Fixity, Standard', role: :standard, groups: [])
        end
        let(:body) { check_body }
        run_test! do
          expect(FixityResult.where(object_key: work.noid)).not_to exist
        end
      end
    end
  end

  def system_headers
    { 'Authorization' => "Bearer #{system_token}", 'User' => "NUID #{system_user.nuid}",
      'Content-Type' => 'application/json' }
  end

  describe 'POST /fixity_checks as an admin', type: :request do
    it 'records a fail with its findings' do
      finding = { code: 'fixity_mismatch', path: 'v1/content/a.tif' }
      post '/fixity_checks', params:  check_body(result: 'fail', findings: [finding]).to_json,
                             headers: { 'Content-Type' => 'application/json' }

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig('fixity_check', 'findings')).to eq([finding.stringify_keys])
      expect(FixityResult.find(work.noid).result).to eq('fail')
    end
  end
end
