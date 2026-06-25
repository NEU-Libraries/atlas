# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'Works', type: :request do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  # Idempotency-Key replay scopes records to the guest user when no other
  # auth context is present; seed one so the rswag examples can persist
  # their setup IdempotencyKey rows.
  let!(:guest) do
    User.find_by(role: :guest) ||
      User.create!(email: 'guest@example.com', password: SecureRandom.hex(16), role: :guest)
  end

  after { Atlas.persister.wipe! }

  path '/works' do
    get 'List works' do
      tags 'Works'
      produces 'application/json'
      description <<~DESC
        Paginated list of all works.

        Pass `?in_progress=true` to see only Works that Cerberus has not
        yet marked complete (operator-friendly "what's stuck?" view).
        Pass `?in_progress=false` to see only completed Works.
      DESC
      parameter name: :in_progress, in: :query, type: :boolean, required: false,
                description: 'Filter by in_progress state. Omit for no filtering.'

      response '200', 'works listed' do
        let(:in_progress) { nil }
        before { 2.times { WorkCreator.call(parent_id: collection.noid) } }
        schema '$ref' => '#/components/schemas/WorksIndex'
        run_test!
      end

      response '200', 'in-progress works listed' do
        let(:in_progress) { true }
        before do
          # one in-progress (default), one completed
          WorkCreator.call(parent_id: collection.noid)
          w = WorkCreator.call(parent_id: collection.noid)
          w.in_progress = false
          Atlas.persister.save(resource: w)
        end
        schema '$ref' => '#/components/schemas/WorksIndex'
        run_test! do |response|
          works = JSON.parse(response.body).fetch('works')
          expect(works.size).to eq(1)
          expect(works.first.dig('work', 'in_progress')).to be true
        end
      end

      response '200', 'completed works listed' do
        let(:in_progress) { false }
        before do
          WorkCreator.call(parent_id: collection.noid)
          w = WorkCreator.call(parent_id: collection.noid)
          w.in_progress = false
          Atlas.persister.save(resource: w)
        end
        schema '$ref' => '#/components/schemas/WorksIndex'
        run_test! do |response|
          works = JSON.parse(response.body).fetch('works')
          expect(works.size).to eq(1)
          expect(works.first.dig('work', 'in_progress')).to be false
        end
      end
    end

    post 'Create a work' do
      tags 'Works'
      consumes 'application/json'
      produces 'application/json'
      description <<~DESC
        Creates a new Work as a child of the given Collection.

        Idempotent on the optional `Idempotency-Key` header: a repeat
        request from the same caller with the same key returns the
        originally-created Work instead of creating a new one. If the
        underlying Work has since been tombstoned, the replay returns
        410 with the tombstone payload (same body shape as GET).
      DESC
      parameter name: :body, in: :body, schema: {
        type:       :object,
        properties: {
          collection_id: { type: :string, description: 'NOID of the parent Collection' }
        },
        required:   %w[collection_id]
      }
      parameter name: :'Idempotency-Key', in: :header, type: :string, required: false,
                description: 'Client-supplied UUID; repeats return the existing resource.'

      response '200', 'work created' do
        let(:body) { { collection_id: collection.noid } }
        let(:'Idempotency-Key') { nil }
        schema '$ref' => '#/components/schemas/Work'
        run_test!
      end

      response '200', 'idempotent replay returns existing work' do
        let(:body) { { collection_id: collection.noid } }
        let(:idempotency_key) { SecureRandom.uuid }
        let(:'Idempotency-Key') { idempotency_key }
        let!(:existing) do
          w = WorkCreator.call(parent_id: collection.noid)
          IdempotencyKey.create!(user: User.find_by(nuid: '000000004'), key: idempotency_key,
                                 resource_type: 'Work', resource_noid: w.noid)
          w
        end
        schema '$ref' => '#/components/schemas/Work'
        run_test! do |response|
          expect(JSON.parse(response.body).dig('work', 'id')).to eq(existing.noid)
        end
      end

      response '410', 'idempotent replay on a tombstoned work' do
        let(:body) { { collection_id: collection.noid } }
        let(:idempotency_key) { SecureRandom.uuid }
        let(:'Idempotency-Key') { idempotency_key }
        let!(:existing) do
          w = WorkCreator.call(parent_id: collection.noid)
          w.tombstoned = true
          w = Atlas.persister.save(resource: w)
          IdempotencyKey.create!(user: User.find_by(nuid: '000000004'), key: idempotency_key,
                                 resource_type: 'Work', resource_noid: w.noid)
          w
        end
        schema '$ref' => '#/components/schemas/Work'
        run_test!
      end
    end
  end

  path '/works/{id}' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Work'

    get 'Retrieve a work' do
      tags 'Works'
      produces 'application/json'

      response '200', 'work found' do
        let(:work) { WorkCreator.call(parent_id: collection.noid) }
        let(:id)   { work.noid }
        schema '$ref' => '#/components/schemas/Work'
        run_test!
      end

      response '410', 'work tombstoned' do
        let(:work) do
          w = WorkCreator.call(parent_id: collection.noid)
          w.tombstoned = true
          Atlas.persister.save(resource: w)
        end
        let(:id) { work.noid }
        schema '$ref' => '#/components/schemas/Work'
        run_test!
      end

      response '200', 'depositor and proxy_uploader project onto the Work JSON' do
        let(:work) do
          WorkCreator.call(
            parent_id:      collection.noid,
            proxy_uploader: '000000002', # librarian on the keyboard
            depositor:      '900000001', # named faculty depositor
            actor_nuid:     '000000002'
          )
        end
        let(:id) { work.noid }
        schema '$ref' => '#/components/schemas/Work'
        run_test! do |response|
          body = JSON.parse(response.body).fetch('work')
          expect(body['depositor']).to      eq('900000001')
          expect(body['proxy_uploader']).to eq('000000002')
        end
      end

      response '200', 'all three thumbnail tiers project onto the Work JSON when Delegates exist' do
        let(:work) { WorkCreator.call(parent_id: collection.noid) }
        let(:id)   { work.noid }
        before do
          DelegateCreator.call(resource_id: work.id, use: Role.thumbnail_image.name,    uri: 'https://iiif.example/85.jpg')
          DelegateCreator.call(resource_id: work.id, use: Role.thumbnail_image_2x.name, uri: 'https://iiif.example/170.jpg')
          DelegateCreator.call(resource_id: work.id, use: Role.preview_image.name,      uri: 'https://iiif.example/500.jpg')
        end
        schema '$ref' => '#/components/schemas/Work'
        run_test! do |response|
          body = JSON.parse(response.body).fetch('work')
          expect(body['thumbnail']).to    eq('https://iiif.example/85.jpg')
          expect(body['thumbnail_2x']).to eq('https://iiif.example/170.jpg')
          expect(body['preview']).to      eq('https://iiif.example/500.jpg')
        end
      end

      response '200', 'ancestor_chain carries each ancestor noid, klass and title (root-first)' do
        let(:work) { WorkCreator.call(parent_id: collection.noid) }
        let(:id)   { work.noid }
        before do
          set_mods_primary_title!(community,  'Root Community')
          set_mods_primary_title!(collection, 'Parent Collection')
        end
        schema '$ref' => '#/components/schemas/Work'
        run_test! do |response|
          chain = JSON.parse(response.body).fetch('work').fetch('ancestor_chain')
          expect(chain).to eq([
                                { 'noid' => community.noid,  'klass' => 'Community',  'title' => 'Root Community' },
                                { 'noid' => collection.noid, 'klass' => 'Collection', 'title' => 'Parent Collection' }
                              ])
        end
      end
    end

    patch 'Update a work' do
      tags 'Works'
      consumes 'multipart/form-data'
      produces 'application/json'
      description <<~DESC
        Update a Work's descriptive metadata by supplying a `binary` MODS XML
        upload — the caller assembles the full document (descriptive merge logic
        lives in the client, e.g. Cerberus, not Atlas). `metadata[permissions]`
        adjusts the ACL. Any `metadata[title]` / `metadata[description]` keys are
        ignored.

        Programmatic Delegate writes (thumbnail-family URIs, sized image
        derivatives) no longer ride this endpoint — see the dedicated
        `PATCH /works/{id}/thumbnails` and `PATCH /works/{id}/image_derivatives`
        routes.
      DESC
      parameter name: :binary, in: :formData, required: false
      multipart_request_body(
        {
          binary: { type: :string, format: :binary, description: 'MODS XML to apply to the Work' }
        }
      )

      response '200', 'work updated' do
        let(:work)   { WorkCreator.call(parent_id: collection.noid) }
        let(:id)     { work.noid }
        let(:binary) { Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/work-mods.xml')) }
        schema '$ref' => '#/components/schemas/Work'
        run_test!
      end

      response '409', 'optimistic-lock conflict on the update (surfaced immediately, not retried)' do
        let(:work)   { WorkCreator.call(parent_id: collection.noid) }
        let(:id)     { work.noid }
        let(:binary) { Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/work-mods.xml')) }
        before do
          work # persist before stubbing so the creator's saves don't hit the stub
          allow(Atlas.persister).to receive(:save).and_raise(Valkyrie::Persistence::StaleObjectError)
        end
        run_test! do |response|
          expect(JSON.parse(response.body)['error']).to eq('stale_resource')
        end
      end
    end

    delete 'Destroy a work' do
      tags 'Works'

      response '204', 'work destroyed' do
        let(:work) { WorkCreator.call(parent_id: collection.noid) }
        let(:id)   { work.noid }
        run_test!
      end
    end
  end

  path '/works/{id}/mods' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Work'

    get 'Retrieve MODS metadata for a work' do
      tags 'Works'
      produces 'application/xml', 'application/json'
      description 'Returns MODS XML by default; pass Accept: application/json for the JSON projection.'

      response '200', 'mods returned' do
        let(:work) { WorkCreator.call(parent_id: collection.noid) }
        let(:id)   { work.noid }
        let(:Accept) { 'application/xml' }
        run_test!
      end
    end
  end

  path '/works/{id}/mets' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Work'

    get 'Retrieve METS structural metadata for a work' do
      tags 'Works'
      produces 'application/json'
      description <<~DESC
        JSON projection of the Work-level structural (METS) metadata. The
        physical structMap records page order (surfaced under mets.pages);
        it is built when the Work is completed (POST /works/:id/complete)
        and rebuilt eagerly on page changes thereafter. 404 for Works that
        have never been completed.
      DESC

      response '200', 'work mets returned' do
        let(:work) { WorkCreator.call(parent_id: collection.noid) }
        let(:id)   { work.noid }
        before do
          FileSetCreator.call(work_id: work.noid, classification: Classification.image, position: 1)
          WorkMETSRebuilder.call(work: work)
        end
        run_test! do |response|
          pages = JSON.parse(response.body).dig('work', 'mets', 'pages')
          expect(pages.pluck('order')).to eq([1])
        end
      end

      response '404', 'work never completed — no METS yet' do
        let(:work) { WorkCreator.call(parent_id: collection.noid) }
        let(:id)   { work.noid }
        run_test!
      end
    end
  end

  path '/works/{id}/assets' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Work'

    get 'List downloadable assets attached to a work' do
      tags 'Works'
      produces 'application/json'
      description <<~DESC
        Returns a polymorphic array of downloadable assets attached to the
        Work: held binaries (Blob entries with size + original_filename)
        and external pointer-only derivatives (Delegate entries with
        use + uri, e.g. IIIF-served sized image variants). Thumbnails
        (Role.thumbnail_image) and metadata roles are excluded by
        Role.downloadable?.
      DESC

      response '200', 'assets listed' do
        let(:work)     { WorkCreator.call(parent_id: collection.noid) }
        let(:id)       { work.noid }
        let(:file_set) { FileSetCreator.call(work_id: work.noid, classification: Classification.image) }
        before do
          BlobCreator.call(path:              Rails.root.join('spec/fixtures/files/example.png').to_s,
                           file_set_id:       file_set.noid,
                           original_filename: 'page1.png')
        end
        schema '$ref' => '#/components/schemas/WorkAssets'
        run_test! do |response|
          blob = JSON.parse(response.body).find { |a| a['original_filename'] == 'page1.png' }
          # Labeled, consumer-facing name: <Label#prefix><noid>.<ext> —
          # distinct from the deposited original_filename.
          expect(blob['filename']).to match(/\.png\z/)
        end
      end

      response '200', 'thumbnail Delegate is excluded; non-thumbnail Delegate is included' do
        let(:work) { WorkCreator.call(parent_id: collection.noid) }
        let(:id)   { work.noid }
        before do
          DelegateCreator.call(
            resource_id: work.id,
            use:         Role.thumbnail_image.name,
            uri:         'https://iiif.example/thumb.jpg'
          )
          # Sized derivative — Role.downloadable? returns true since it's
          # not in the blocklist. Acts as a stand-in for a future
          # small/medium/large_image role.
          DelegateCreator.call(
            resource_id: work.id,
            use:         Role.service_file.name,
            uri:         'https://iiif.example/service.jpg'
          )
        end
        schema '$ref' => '#/components/schemas/WorkAssets'
        run_test! do |response|
          assets = JSON.parse(response.body)
          uses = assets.pluck('use').compact
          expect(uses).to include(Role.service_file.name)
          expect(uses).not_to include(Role.thumbnail_image.name)
        end
      end
    end
  end

  path '/works/{id}/file_sets' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Work'

    get "List a work's page FileSets in order" do
      tags 'Works'
      produces 'application/json'
      description <<~DESC
        Ordered page listing for multipage Works: one entry per page-bearing
        FileSet (descriptive/structural-metadata and derivative FileSets are
        excluded), sorted position ASC with unordered (null) FileSets last,
        creation-order tie-break. Each entry nests its downloadable assets —
        the page's content Blobs plus any per-page IIIF Delegates living in
        a derivative FileSet under the page. Unpaginated by design: manifest
        assembly needs the whole sequence in one read.
      DESC

      response '200', 'page file sets listed in order' do
        let(:work) { WorkCreator.call(parent_id: collection.noid) }
        let(:id)   { work.noid }
        before do
          # created out of order on purpose — position drives the sort
          FileSetCreator.call(work_id: work.noid, classification: Classification.image, position: 2)
          FileSetCreator.call(work_id: work.noid, classification: Classification.image, position: 1)
          FileSetCreator.call(work_id: work.noid, classification: Classification.image) # legacy/unordered
        end
        schema '$ref' => '#/components/schemas/WorkFileSets'
        run_test! do |response|
          pages = JSON.parse(response.body)
          expect(pages.length).to eq(3)
          expect(pages.pluck('position')).to eq([1, 2, nil])
          expect(pages.pluck('type')).not_to include(Classification.descriptive_metadata.name)
        end
      end

      response '200', 'assets stay grouped under their page' do
        let(:work)     { WorkCreator.call(parent_id: collection.noid) }
        let(:id)       { work.noid }
        let(:page_one) { FileSetCreator.call(work_id: work.noid, classification: Classification.image, position: 1) }
        let(:page_two) { FileSetCreator.call(work_id: work.noid, classification: Classification.image, position: 2) }
        before do
          BlobCreator.call(path:              Rails.root.join('spec/fixtures/files/example.png').to_s,
                           file_set_id:       page_one.noid,
                           original_filename: 'page1.png')
          # Per-page IIIF Delegate — lands in a derivative FileSet nested
          # under the page, and must surface as that page's asset.
          DelegateCreator.call(resource_id: page_two.noid, use: Role.service_file.name,
                               uri: 'https://iiif.example/page2.jpg')
          # Work-level derivative container must not surface as a page entry.
          DelegateCreator.call(resource_id: work.id, use: Role.service_file.name,
                               uri: 'https://iiif.example/work.jpg')
        end
        schema '$ref' => '#/components/schemas/WorkFileSets'
        run_test! do |response|
          pages = JSON.parse(response.body)
          expect(pages.length).to eq(2)
          expect(pages[0]['assets'].pluck('original_filename')).to include('page1.png')
          expect(pages[1]['assets'].pluck('uri')).to include('https://iiif.example/page2.jpg')
        end
      end

      response '404', 'work not found' do
        let(:id) { 'nonexistent' }
        run_test!
      end
    end
  end

  path '/works/{id}/thumbnails' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Work'

    patch 'Attach thumbnail-family IIIF Delegate URIs to a work' do
      tags 'Works'
      consumes 'application/json'
      produces 'application/json'
      description <<~DESC
        Upserts one or more thumbnail-tier Delegates on the Work — the
        85px `thumbnail`, the 170px `thumbnail_2x`, and the 500px hero
        `preview`. Each non-blank URI is dispatched to DelegateUpdater
        against its matching Role; missing keys are left untouched.

        Purpose-specific: machine-set IIIF URLs, fixed three-key shape,
        no user content. Cerberus's ThumbnailCreationJob is the primary
        caller.
      DESC
      parameter name: :body, in: :body, schema: {
        type:       :object,
        properties: {
          thumbnail:    { type: :string, description: 'IIIF URL for the 85px thumbnail tier' },
          thumbnail_2x: { type: :string, description: 'IIIF URL for the 170px retina thumbnail tier' },
          preview:      { type: :string, description: 'IIIF URL for the 500px hero preview tier' }
        }
      }

      response '200', 'thumbnail Delegate is created and surfaces on read' do
        let(:work) { WorkCreator.call(parent_id: collection.noid) }
        let(:id) { work.noid }
        let(:body) { { thumbnail: 'https://iiif.example/iiif/2/abc/full/!200,200/0/default.jpg' } }
        schema '$ref' => '#/components/schemas/Work'
        run_test! do |response|
          expect(JSON.parse(response.body).dig('work', 'thumbnail'))
            .to eq('https://iiif.example/iiif/2/abc/full/!200,200/0/default.jpg')

          reloaded = Work.find(work.noid)
          deriv_fs = reloaded.children.find { |c| c.is_a?(FileSet) && c.type == Classification.derivative.name }
          expect(deriv_fs).not_to be_nil
          members = Atlas.query.find_members(resource: deriv_fs).to_a
          expect(members.size).to eq(1)
          expect(members.first).to be_a(Delegate)
          expect(members.first.use).to eq(Role.thumbnail_image.name)
        end
      end

      response '200', 'all three thumbnail-family keys land in one PATCH' do
        let(:work) { WorkCreator.call(parent_id: collection.noid) }
        let(:id)   { work.noid }
        let(:body) do
          {
            thumbnail:    'https://iiif.example/iiif/3/abc.jp2/full/!85,85/0/default.jpg',
            thumbnail_2x: 'https://iiif.example/iiif/3/abc.jp2/full/!170,170/0/default.jpg',
            preview:      'https://iiif.example/iiif/3/abc.jp2/full/500,/0/default.jpg'
          }
        end
        schema '$ref' => '#/components/schemas/Work'
        run_test! do |response|
          json = JSON.parse(response.body).fetch('work')
          expect(json['thumbnail']).to eq('https://iiif.example/iiif/3/abc.jp2/full/!85,85/0/default.jpg')
          expect(json['thumbnail_2x']).to eq('https://iiif.example/iiif/3/abc.jp2/full/!170,170/0/default.jpg')
          expect(json['preview']).to eq('https://iiif.example/iiif/3/abc.jp2/full/500,/0/default.jpg')

          reloaded = Work.find(work.noid)
          deriv_fs = reloaded.children.find { |c| c.is_a?(FileSet) && c.type == Classification.derivative.name }
          members  = Atlas.query.find_members(resource: deriv_fs).to_a.select { |m| m.is_a?(Delegate) }
          uses     = members.map(&:use)
          expect(uses).to contain_exactly(
            Role.thumbnail_image.name,
            Role.thumbnail_image_2x.name,
            Role.preview_image.name
          )
        end
      end

      response '409', 'optimistic-lock conflict survived the internal retry budget' do
        let(:work) { WorkCreator.call(parent_id: collection.noid) }
        let(:id)   { work.noid }
        let(:body) { { thumbnail: 'https://iiif.example/iiif/2/abc/full/!85,85/0/default.jpg' } }
        before do
          allow_any_instance_of(WorksController).to receive(:sleep)
          allow(DelegateUpdater).to receive(:call).and_raise(Valkyrie::Persistence::StaleObjectError)
        end
        run_test! do |response|
          expect(JSON.parse(response.body)['error']).to eq('stale_resource')
        end
      end
    end
  end

  path '/works/{id}/image_derivatives' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Work'

    patch 'Attach sized-image IIIF Delegate URIs to a work' do
      tags 'Works'
      consumes 'application/json'
      produces 'application/json'
      description <<~DESC
        Upserts one or more downloadable image-derivative Delegates on
        the Work — `small`, `medium`, and `large` IIIF URLs. Each
        non-blank URI is dispatched to DelegateUpdater against its
        matching Role (small_image / medium_image / large_image);
        missing keys are left untouched.

        Sibling of `/thumbnails`. These derivatives surface in
        `/works/{id}/assets` and are intended to be downloaded directly
        rather than rendered as UI chrome.
      DESC
      parameter name: :body, in: :body, schema: {
        type:       :object,
        properties: {
          small:  { type: :string, description: 'IIIF URL for the small image tier' },
          medium: { type: :string, description: 'IIIF URL for the medium image tier' },
          large:  { type: :string, description: 'IIIF URL for the large image tier' }
        }
      }

      response '200', 'all three image-derivative keys land in one PATCH' do
        let(:work) { WorkCreator.call(parent_id: collection.noid) }
        let(:id) { work.noid }
        let(:body) do
          {
            small:  'https://iiif.example/iiif/3/abc.jp2/full/800,/0/default.jpg',
            medium: 'https://iiif.example/iiif/3/abc.jp2/full/1600,/0/default.jpg',
            large:  'https://iiif.example/iiif/3/abc.jp2/full/full/0/default.jpg'
          }
        end
        schema '$ref' => '#/components/schemas/Work'
        run_test! do
          reloaded = Work.find(work.noid)
          deriv_fs = reloaded.children.find { |c| c.is_a?(FileSet) && c.type == Classification.derivative.name }
          members = Atlas.query.find_members(resource: deriv_fs).to_a.select { |m| m.is_a?(Delegate) }
          uris_by_use = members.to_h { |m| [m.use, m.uri] }
          expect(uris_by_use).to eq(
            Role.small_image.name  => 'https://iiif.example/iiif/3/abc.jp2/full/800,/0/default.jpg',
            Role.medium_image.name => 'https://iiif.example/iiif/3/abc.jp2/full/1600,/0/default.jpg',
            Role.large_image.name  => 'https://iiif.example/iiif/3/abc.jp2/full/full/0/default.jpg'
          )
        end
      end

      response '409', 'optimistic-lock conflict survived the internal retry budget' do
        let(:work) { WorkCreator.call(parent_id: collection.noid) }
        let(:id)   { work.noid }
        let(:body) { { small: 'https://iiif.example/iiif/3/abc.jp2/full/800,/0/default.jpg' } }
        before do
          allow_any_instance_of(WorksController).to receive(:sleep)
          allow(DelegateUpdater).to receive(:call).and_raise(Valkyrie::Persistence::StaleObjectError)
        end
        run_test! do |response|
          expect(JSON.parse(response.body)['error']).to eq('stale_resource')
        end
      end
    end
  end

  path '/works/{id}/full_text' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Work'

    patch 'Store a work’s derived full-document text' do
      tags 'Works'
      consumes 'application/json'
      produces 'application/json'
      description <<~DESC
        Stores the Work-level aggregate of Cerberus-extracted document text as
        the Work's derived `full_text` attribute. FullTextIndexer projects it
        onto the Work's Solr doc as the dedicated `full_text_tesimv` field for
        body-text search and the "Full Text Match" snippet.

        Same "machine-set derived metadata" seam as `/thumbnails` — a
        regenerable search aid re-sent on any re-ingest, never user-authored.
        Cerberus's FullTextExtractionJob is the primary caller. The response
        omits the text (a long PDF is MBs); it's read back only through Solr.
      DESC
      parameter name: :body, in: :body, schema: {
        type:       :object,
        properties: {
          text: { type: :string, description: 'Extracted plain text (Work-level aggregate of content FileSets)' }
        },
        required:   %w[text]
      }

      response '200', 'full text stored and projected to full_text_tesimv' do
        let(:work) { WorkCreator.call(parent_id: collection.noid) }
        let(:id)   { work.noid }
        let(:body) { { text: 'Running Boston Jon Masters DESCRIPTION: I have a good friend' } }
        schema '$ref' => '#/components/schemas/Work'
        run_test! do
          # Stored on the Work (source of truth)...
          expect(Work.find(work.noid).full_text).to include('Running Boston')
          # ...and projected onto the Work's Solr doc (dedicated full_text_tesimv).
          doc = Atlas.index_adapter.connection.get(
            'select', params: { q: %(id:"#{work.id}"), fl: 'id' }
          ).dig('response', 'docs').first
          expect(doc).not_to be_nil
        end
      end

      response '409', 'optimistic-lock conflict survived the internal retry budget' do
        let(:work) { WorkCreator.call(parent_id: collection.noid) }
        let(:id)   { work.noid }
        let(:body) { { text: 'some text' } }
        before do
          work # materialize before stubbing so creation isn't caught by the stub
          allow_any_instance_of(WorksController).to receive(:sleep)
          allow(Atlas.persister).to receive(:save).and_raise(Valkyrie::Persistence::StaleObjectError)
        end
        run_test! do |response|
          expect(JSON.parse(response.body)['error']).to eq('stale_resource')
        end
      end
    end
  end

  path '/works/{id}/parent' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Work to move'

    patch 'Re-parent a work' do
      tags 'Works'
      consumes 'application/json'
      produces 'application/json'
      description <<~DESC
        Moves a Work to a different Collection. Trivial sibling of the
        collection/community re-parent: a Work has no descendants and carries
        no ancestry field, so there is NO cascade — only its own a_member_of
        changes. Permissions are untouched. Rejects a non-Collection parent
        and tombstoned node/parent with a 422.
      DESC
      parameter name: :body, in: :body, schema: {
        type:       :object,
        required:   %w[parent_id],
        properties: { parent_id: { type: :string, description: 'NOID of the destination Collection' } }
      }

      response '200', 'work moved to another collection' do
        let(:destination) { CollectionCreator.call(parent_id: community.noid) }
        let(:work)        { WorkCreator.call(parent_id: collection.noid) }
        let(:id)          { work.noid }
        let(:body)        { { parent_id: destination.noid } }
        schema '$ref' => '#/components/schemas/Work'
        run_test! do |response|
          ancestors = JSON.parse(response.body).dig('work', 'ancestors')
          expect(ancestors.map(&:first)).to include(destination.noid)
        end
      end

      response '404', 'unknown work' do
        let(:id)   { 'doesnotexist' }
        let(:body) { { parent_id: collection.noid } }
        run_test!
      end
    end
  end

  path '/works/{id}/linked_members' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Work'

    get 'List the collections a work is linked into' do
      tags 'Works'
      produces 'application/json'
      description <<~DESC
        Returns the NOIDs of the Collections this Work is a *linked* member of
        (the DAG overlay — additional placements beyond its one structural
        home). Powers Cerberus's provenance panel. Does not include the
        structural parent (that's `a_member_of`, surfaced via ancestors).
      DESC

      response '200', 'linked collections listed' do
        let(:destination) { CollectionCreator.call(parent_id: community.noid) }
        let(:work) do
          w = WorkCreator.call(parent_id: collection.noid)
          LinkedMemberCreator.call(work: w, collection: destination)
          w
        end
        let(:id) { work.noid }
        schema type: :array, items: { type: :string }
        run_test! do |response|
          expect(JSON.parse(response.body)).to include(destination.noid)
        end
      end
    end

    post 'Link a work into an additional collection' do
      tags 'Works'
      consumes 'application/json'
      produces 'application/json'
      description <<~DESC
        Adds the Work as a linked member of the target Collection — placement
        only, never a permission change. Admin-only: linking a Work into
        additional Collections is a structural mutation of the content graph,
        so edit rights are not sufficient. Rejects a non-Collection target, a
        tombstoned work/target, and a target that is already the Work's
        structural home, with a 422. Returns the updated
        list of linked collection NOIDs.
      DESC
      parameter name: :body, in: :body, schema: {
        type:       :object,
        required:   %w[collection_id],
        properties: { collection_id: { type: :string, description: 'NOID of the Collection to link into' } }
      }

      response '200', 'work linked into the collection' do
        let(:destination) { CollectionCreator.call(parent_id: community.noid) }
        let(:work)        { WorkCreator.call(parent_id: collection.noid) }
        let(:id)          { work.noid }
        let(:body)        { { collection_id: destination.noid } }
        schema type: :array, items: { type: :string }
        run_test! do |response|
          expect(JSON.parse(response.body)).to include(destination.noid)
        end
      end

      response '422', 'rejects a non-Collection target' do
        let(:other_community) { CommunityCreator.call }
        let(:work)            { WorkCreator.call(parent_id: collection.noid) }
        let(:id)              { work.noid }
        let(:body)            { { collection_id: other_community.noid } }
        run_test! do |response|
          expect(JSON.parse(response.body)['error']).to eq('invalid_target_type')
        end
      end
    end
  end

  path '/works/{id}/linked_members/{collection_id}' do
    parameter name: :id, in: :path, type: :string, description: 'NOID of the Work'
    parameter name: :collection_id, in: :path, type: :string, description: 'NOID of the linked Collection to remove'

    delete 'Unlink a work from a collection' do
      tags 'Works'
      produces 'application/json'
      description <<~DESC
        Removes a linked membership (idempotent — removing an absent link is a
        no-op). Admin-only, same as the add. Returns the updated list of
        linked collection NOIDs. Permissions are never changed.
      DESC

      response '200', 'work unlinked from the collection' do
        let(:destination) { CollectionCreator.call(parent_id: community.noid) }
        let(:work) do
          w = WorkCreator.call(parent_id: collection.noid)
          LinkedMemberCreator.call(work: w, collection: destination)
          w
        end
        let(:id)            { work.noid }
        let(:collection_id) { destination.noid }
        schema type: :array, items: { type: :string }
        run_test! do |response|
          expect(JSON.parse(response.body)).not_to include(destination.noid)
        end
      end
    end
  end

  path '/works/{id}/tombstone' do
    parameter name: :id, in: :path, type: :string

    post 'Tombstone a work' do
      tags 'Works'
      produces 'application/json'
      description 'Marks a Work as tombstoned. Always succeeds; FileSets and Blobs ride along with the parent Work.'

      response '200', 'work tombstoned' do
        let(:work) { WorkCreator.call(parent_id: collection.noid) }
        let(:id)   { work.noid }
        schema '$ref' => '#/components/schemas/Work'
        run_test!
      end
    end
  end

  path '/works/{id}/restore' do
    parameter name: :id, in: :path, type: :string

    post 'Restore a tombstoned work' do
      tags 'Works'
      produces 'application/json'
      description 'Clears the tombstone flag on a Work. Cerberus does not expose this — call from operator console.'

      response '200', 'work restored' do
        let(:work) do
          w = WorkCreator.call(parent_id: collection.noid)
          w.tombstoned = true
          Atlas.persister.save(resource: w)
        end
        let(:id) { work.noid }
        schema '$ref' => '#/components/schemas/Work'
        run_test!
      end
    end
  end

  path '/works/{id}/complete' do
    parameter name: :id, in: :path, type: :string

    post 'Mark a work complete' do
      tags 'Works'
      produces 'application/json'
      description <<~DESC
        Flips `in_progress` to false. Cerberus calls this after its
        per-record Solid Queue job confirms all expected children
        (FileSets / Blobs) are deposited. Idempotent — calling on an
        already-complete Work simply re-saves with in_progress: false.
      DESC

      response '200', 'work marked complete' do
        let(:work) { WorkCreator.call(parent_id: collection.noid) }
        let(:id)   { work.noid }
        schema '$ref' => '#/components/schemas/Work'
        run_test! do |response|
          expect(JSON.parse(response.body).dig('work', 'in_progress')).to be false
        end
      end

      response '200', 'completing builds the Work-level METS structMap' do
        let(:work) { WorkCreator.call(parent_id: collection.noid) }
        let(:id)   { work.noid }
        before do
          # created out of order — the structMap sorts by position
          FileSetCreator.call(work_id: work.noid, classification: Classification.image, position: 2)
          FileSetCreator.call(work_id: work.noid, classification: Classification.image, position: 1)
        end
        schema '$ref' => '#/components/schemas/Work'
        run_test! do
          record = Metadata::METS.find_by(valkyrie_id: work.noid)
          expect(record).not_to be_nil
          expect(record.pages.map(&:order)).to eq([1, 2])
        end
      end

      response '409', 'optimistic-lock conflict survived the internal retry budget' do
        let(:work) { WorkCreator.call(parent_id: collection.noid) }
        let(:id)   { work.noid }
        before do
          work # persist before stubbing so the creator's saves don't hit the stub
          allow_any_instance_of(WorksController).to receive(:sleep)
          allow(Atlas.persister).to receive(:save).and_raise(Valkyrie::Persistence::StaleObjectError)
        end
        run_test! do |response|
          expect(JSON.parse(response.body)['error']).to eq('stale_resource')
        end
      end
    end
  end

  # Gap C regression — see collections_spec / permissions_spec for the
  # full rationale.
  describe 'PATCH /works/:id with ACL-only metadata preserves provenance' do
    it 'leaves depositor/proxy_uploader intact when metadata[permissions] omits them' do
      work = WorkCreator.call(
        parent_id:      collection.noid,
        proxy_uploader: '000000002',
        depositor:      '900000001',
        actor_nuid:     '000000002'
      )
      expect(work.depositor).to      eq('900000001')
      expect(work.proxy_uploader).to eq('000000002')

      patch "/works/#{work.noid}",
            params: { metadata: { permissions: { read: ['public'], edit: [], edit_users: [] } } }

      expect(response).to have_http_status(:ok)
      reloaded = Work.find(work.noid)
      expect(reloaded.depositor).to      eq('900000001')
      expect(reloaded.proxy_uploader).to eq('000000002')
      expect(reloaded.read_groups.to_a).to eq(['public'])
    end
  end
end
