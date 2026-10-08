# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'Darwin Core records', type: :request do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  let(:dwc_path)   { Rails.root.join('spec/fixtures/files/dwc.xml') }
  let(:dwc_upload) { Rack::Test::UploadedFile.new(dwc_path, 'application/xml') }
  let(:editor_nuid) { '000000004' }

  let!(:guest) do
    User.find_by(role: :guest) ||
      User.create!(email: 'guest@example.invalid', password: SecureRandom.hex(16),
                   nuid: '000000001', name: 'User, Guest', role: :guest)
  end

  # Version labels are opaque OCFL vN, and a reused NOID would carry versions
  # over from an earlier example; see mods_versions_spec.rb.
  before { FileUtils.rm_rf(TestStorage.root) }
  after { Atlas.persister.wipe! }

  def put_dwc(noid, fixture: dwc_path, **extra)
    put "/resources/#{noid}/dwc", params: { binary: Rack::Test::UploadedFile.new(fixture, 'application/xml'), **extra }
  end

  def dwc_events(resource)
    AuditEvent.for_resource(resource.id.to_s).where(change_type: 'metadata').where("payload->>'source' = 'dwc'")
  end

  path '/works/{id}/dwc' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Work'

    get "Retrieve a work's Darwin Core record" do
      tags 'Works'
      produces 'application/json', 'application/xml'
      description <<~DESC
        The Work's Darwin Core record. JSON by default: each term of the single
        dwr:SimpleDarwinRecord, keyed by its term name. Append `.xml`
        (/works/{id}/dwc.xml) for the stored Simple Darwin Core document,
        byte for byte, as a standalone download.

        Gated like `/works/{id}/mods`: whoever may read the Work may read its
        record. 404 when the Work holds no record, including one that has been
        withdrawn, and for any NOID that is not a Work. The Work JSON's
        `metadata_formats` says whether to call this.
      DESC

      response '200', 'darwin core returned' do
        let(:id) { work.noid }
        before { put_dwc(work.noid) }
        schema '$ref' => '#/components/schemas/WorkDarwinCore'
        run_test! do |response|
          expect(response.parsed_body.dig('work', 'dwc', 'catalogNumber')).to eq('MVZ:Mamm:14523')
        end
      end

      response '404', 'the work holds no record, or the id is not a work' do
        let(:id) { work.noid }
        run_test!
      end
    end
  end

  path '/resources/{id}/dwc' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Work'

    put "Replace a work's Darwin Core record" do
      tags 'Resources'
      consumes 'multipart/form-data'
      produces 'application/json'
      description <<~DESC
        Replaces the Work's Darwin Core record with the supplied `binary`, a
        Simple Darwin Core XML document. PUT because the caller sends the whole
        document. The first PUT creates the record; a PUT onto a withdrawn
        record restores it. Each PUT appends an OCFL version.

        Atlas checks the shape only, and answers 422 with an `error` code when
        a rule fails: `malformed_xml` (not well-formed), `invalid_root` (the
        root is not dwr:SimpleDarwinRecordSet), `record_count` (not exactly one
        dwr:SimpleDarwinRecord) or `duplicate_term` (a term appears twice).
        Schema validation against tdwg_dwc_simple.xsd is the caller's. A
        request with no `binary` is a bare 422.

        Works only: any other NOID answers 404. Gated by `:update` on the Work.
        Writes an audit event with change type `metadata` and source `dwc`.
      DESC
      parameter name: :binary, in: :formData, required: false
      parameter name: :origin, in: :formData, required: false
      multipart_request_body(
        {
          binary: { type: :string, format: :binary, description: 'Simple Darwin Core XML for the work' },
          origin: { type: :string, description: ORIGIN_PARAM_DESCRIPTION }
        }
      )

      response '200', 'darwin core replaced' do
        let(:id)     { work.noid }
        let(:binary) { dwc_upload }
        schema '$ref' => '#/components/schemas/WorkDarwinCore'
        run_test!
      end

      response '404', 'unknown id, or not a work' do
        let(:id)     { collection.noid }
        let(:binary) { dwc_upload }
        run_test!
      end

      response '422', 'the document breaks a shape rule' do
        let(:id)     { work.noid }
        let(:binary) { Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/dwc-two-records.xml')) }
        run_test! do |response|
          expect(response.parsed_body['error']).to eq('record_count')
        end
      end
    end

    delete "Withdraw a work's Darwin Core record" do
      tags 'Resources'
      description <<~DESC
        Withdraws the record: `GET /works/{id}/dwc` answers 404 and the Work
        JSON drops `dwc` from `metadata_formats`. Nothing is purged. The
        preserved document and its version history stay, and the next PUT
        restores the record. 404 when the Work holds no record, and for any
        NOID that is not a Work. Gated by `:update` on the Work.
      DESC

      response '204', 'record withdrawn' do
        let(:id) { work.noid }
        before { put_dwc(work.noid) }
        run_test!
      end

      response '404', 'nothing to withdraw' do
        let(:id) { work.noid }
        run_test!
      end
    end
  end

  path '/resources/{id}/dwc/versions' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Work'

    get "List a work's Darwin Core version history" do
      tags 'Resources'
      produces 'application/json'
      description <<~DESC
        Newest-first list of the retained Darwin Core versions, in the same
        shape as `/resources/{id}/mods/versions` and under the same admin gate,
        because the descriptors carry edit attribution. Attribution comes from
        the `dwc` audit events only. A Work with no record, or a NOID that is
        not a Work, yields `{ "versions": [] }`.
      DESC

      response '200', 'versions listed (newest first)' do
        let(:id) { work.noid }
        before { put_dwc(work.noid) }
        schema '$ref' => '#/components/schemas/ModsVersions'
        run_test! do |response|
          expect(response.parsed_body['versions'].first).to include('actor_nuid' => editor_nuid, 'source' => 'dwc')
        end
      end
    end
  end

  path '/resources/{id}/dwc/versions/{version_id}' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Work'
    parameter name: :version_id, in: :path, type: :string, description: 'OCFL version label, e.g. v3'

    get 'Fetch Darwin Core XML as of a specific version' do
      tags 'Resources'
      produces 'application/xml'
      description <<~DESC
        The stored dwc.xml as of the given OCFL version. XML only, because the
        JSON access copy is overwritten in place. Gated by `:read` on the Work.
        Unknown version, or no record ever written, answers 404.
      DESC

      response '200', 'historical darwin core returned' do
        let(:id) { work.noid }
        let(:version_id) do
          put_dwc(work.noid)
          Work.find(work.noid).darwin_core_blob.latest_revision.to_s.split('/')[-2]
        end
        run_test! do |response|
          expect(response.body).to eq(dwc_path.read)
        end
      end

      response '404', 'unknown version' do
        let(:id)         { work.noid }
        let(:version_id) { 'v9999' }
        run_test!
      end
    end
  end

  describe 'reading the record' do
    before { put_dwc(work.noid) }

    it 'serves the stored document byte for byte via .xml' do
      get "/works/#{work.noid}/dwc.xml"
      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include('xml')
      expect(response.body).to eq(dwc_path.read)
    end

    it 'answers 404 on the typed route for a NOID that is not a Work' do
      get "/works/#{collection.noid}/dwc"
      expect(response).to have_http_status(:not_found)
    end

    it 'follows the Work read gate' do
      patch "/resources/#{work.noid}/permissions", params: { permissions: { read: [] } }, as: :json
      get "/works/#{work.noid}/dwc", headers: signed_auth_headers(guest.nuid)
      expect(response).to have_http_status(:forbidden)
    end

    it 'advertises the record on the Work JSON' do
      get "/works/#{work.noid}"
      expect(response.parsed_body.dig('work', 'metadata_formats')).to eq(['dwc'])
    end
  end

  describe 'writing the record' do
    it 'records an audit event with the dwc source and the given origin' do
      put_dwc(work.noid, origin: 'xml_loader')
      expect(response).to have_http_status(:ok)

      event = dwc_events(work).sole
      expect(event).to have_attributes(action: 'update', actor_nuid: editor_nuid)
      expect(event.payload).to eq('source' => 'dwc', 'origin' => 'xml_loader')
    end

    it 'names the broken TDWG example malformed, and stores nothing' do
      put_dwc(work.noid, fixture: Rails.root.join('spec/fixtures/files/dwc-tdwg-example-broken.xml'))
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include('error' => 'malformed_xml', 'resource_id' => work.noid)
      expect(Work.find(work.id).darwin_core_blob).to be_nil
      expect(dwc_events(work)).to be_empty
    end

    it 'refuses a MODS document as the wrong root' do
      put_dwc(work.noid, fixture: Rails.root.join('spec/fixtures/files/work-mods.xml'))
      expect(response.parsed_body['error']).to eq('invalid_root')
    end

    it 'answers 422 with no binary' do
      put "/resources/#{work.noid}/dwc"
      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'is refused to a guest' do
      put "/resources/#{work.noid}/dwc", params: { binary: dwc_upload }, headers: signed_auth_headers(guest.nuid)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'withdrawing and restoring the record' do
    before { put_dwc(work.noid) }

    it 'hides the record, records the withdrawal, and keeps the history' do
      delete "/resources/#{work.noid}/dwc"
      expect(response).to have_http_status(:no_content)

      get "/works/#{work.noid}/dwc"
      expect(response).to have_http_status(:not_found)
      get "/works/#{work.noid}"
      expect(response.parsed_body.dig('work', 'metadata_formats')).to eq([])
      expect(dwc_events(work).pluck(:action)).to contain_exactly('update', 'tombstone')

      get "/resources/#{work.noid}/dwc/versions"
      expect(response.parsed_body['versions'].length).to eq(1)
    end

    it 'brings the record back on the next PUT, as a new version' do
      delete "/resources/#{work.noid}/dwc"
      put_dwc(work.noid, fixture: Rails.root.join('spec/fixtures/files/dwc-other.xml'))
      expect(response).to have_http_status(:ok)

      get "/works/#{work.noid}/dwc"
      expect(response.parsed_body.dig('work', 'dwc', 'catalogNumber')).to eq('MVZ:Mamm:14524')
      get "/resources/#{work.noid}/dwc/versions"
      expect(response.parsed_body['versions'].length).to eq(2)
    end
  end

  describe 'the version history' do
    it 'is admin-gated like the MODS history' do
      get "/resources/#{work.noid}/dwc/versions", headers: signed_auth_headers(guest.nuid)
      expect(response).to have_http_status(:forbidden)
    end

    it 'is empty for a Work with no record and for a NOID that is not a Work' do
      [work, collection].each do |resource|
        get "/resources/#{resource.noid}/dwc/versions"
        expect(response.parsed_body['versions']).to eq([])
      end
    end

    # The two records share the `metadata` change type, so each history must
    # keep to its own events.
    it 'stays apart from the MODS history' do
      put_dwc(work.noid)
      get "/resources/#{work.noid}/mods/versions"
      expect(response.parsed_body['versions'].pluck('source')).not_to include('dwc')
    end
  end
end
