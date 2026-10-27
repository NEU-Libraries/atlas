# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'Fixity checks', type: :request do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }
  let!(:checker) do
    User.create!(email: 'fixity@example.invalid', password: SecureRandom.hex(16),
                 nuid: User::FIXITY_CHECKER_NUID, name: 'User, Fixity Checker', role: :fixity_checker)
  end
  let(:fixity_token) { 'test-fixity-token' }

  before { allow(Rails.application.credentials).to receive(:fixity_token).and_return(fixity_token) }
  after  { Atlas.persister.wipe! }

  def check_body(**overrides)
    { object: "urn:neu-drs:#{work.noid}", checked_at: '2026-10-27T03:12:09Z', version: 'v1',
      algorithm: 'sha512', files: 3, result: 'pass', findings: [], checker: 'ocfl-fixity-sweep 1.0' }
      .merge(overrides)
  end

  path '/fixity_checks' do
    post 'Record one fixity check result for an OCFL object (fixity checker and admin only)' do
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

        The `:fixity_checker` principal (its own `fixity_token`) and admins
        only. Anyone else gets 403. An object no resource holds is a 404; an
        unknown version, or a resource with no OCFL object, is a 422 that
        writes nothing.
      DESC
      security [{ BearerAuth: [] }]
      parameter name: :Authorization, in: :header, type: :string, required: false
      parameter name: :User, in: :header, type: :string, required: false,
                description: 'The checker fixture, "NUID 000000098"'
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

      let(:Authorization) { "Bearer #{fixity_token}" }
      let(:User)          { "NUID #{checker.nuid}" }

      response '201', 'check recorded' do
        let(:body) { check_body }
        schema '$ref' => '#/components/schemas/FixityCheck'
        run_test! do |response|
          expect(response.parsed_body['fixity_check'])
            .to include('resource_id' => work.noid, 'result' => 'pass', 'latest' => true,
                        'recorded_by' => User::FIXITY_CHECKER_NUID)
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

      response '403', 'not the fixity checker or an admin' do
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
    { 'Authorization' => "Bearer #{fixity_token}", 'User' => "NUID #{checker.nuid}",
      'Content-Type' => 'application/json' }
  end

  path '/fixity_checks/due' do
    get 'List the OCFL objects most in need of a fixity check (fixity checker and admin only)' do
      tags 'Resources'
      produces 'application/json'
      description <<~DESC
        The objects to check next: never checked first, then oldest check
        first. Read off the storage ledger, so it lists every object the
        storage adapter has written, checked or not. `bytes` is the object's
        size on disk, for planning; the sweep holds its budget by counting what
        it actually hashes.

        `checked_before` limits the list to objects not checked since that
        time. A sweep passes its own start, so each object it records drops
        out and the next page needs no cursor. It defaults to now.

        Refused during a maintenance window, so a sweep stops before it hashes
        anything it could not record.
      DESC
      security [{ BearerAuth: [] }]
      parameter name: :Authorization, in: :header, type: :string, required: false
      parameter name: :User, in: :header, type: :string, required: false,
                description: 'The checker fixture, "NUID 000000098"'
      parameter name: :limit, in: :query, required: false,
                schema: { type: :integer, minimum: 1, maximum: FixityDueQuery::MAX_LIMIT, default: 100 }
      parameter name: :checked_before, in: :query, required: false, schema: { type: :string, format: 'date-time' },
                description: 'List only objects not checked since this time'

      let(:Authorization)  { "Bearer #{fixity_token}" }
      let(:User)           { "NUID #{checker.nuid}" }
      let(:limit)          { 1000 }
      let(:checked_before) { Time.current.utc.iso8601 }

      response '200', 'objects due, never checked first' do
        before do
          FixityResult.advance!(key: work.noid, checked_at: Time.utc(2026, 1, 1), result: 'pass',
                                version: 'v1', checker: 'spec')
        end

        schema '$ref' => '#/components/schemas/FixityDue'
        run_test! do |response|
          keys = response.parsed_body['due'].pluck('key')
          unchecked = work.preserved_resources.map(&:noid) - [work.noid]
          expect(keys).to include(work.noid, *unchecked)
          expect(keys.index(work.noid)).to be > unchecked.map { |key| keys.index(key) }.max
        end
      end

      response '400', 'checked_before is not a timestamp' do
        let(:checked_before) { 'last night' }
        run_test!
      end

      response '403', 'not the fixity checker or an admin' do
        let(:Authorization) { "Bearer #{DefaultAuthHeaders.assertion_for('000000072')}" }
        let(:User)          { nil }
        before do
          User.create!(email: 'fixity-due-standard@example.invalid', password: SecureRandom.hex(16),
                       nuid: '000000072', name: 'Due, Standard', role: :standard, groups: [])
        end
        run_test!
      end
    end
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
