# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'Works', type: :request do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  # Idempotency-Key replay scopes records to the guest user when no other
  # auth context is present; seed one so the rswag examples can persist
  # their setup IdempotencyKey rows.
  let!(:guest) do
    User.find_by_role(:guest) ||
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
        type: :object,
        properties: {
          collection_id: { type: :string, description: 'NOID of the parent Collection' }
        },
        required: %w[collection_id]
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
          IdempotencyKey.create!(user: guest, key: idempotency_key,
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
          IdempotencyKey.create!(user: guest, key: idempotency_key,
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
    end

    patch 'Update a work' do
      tags 'Works'
      consumes 'multipart/form-data'
      produces 'application/json'
      description <<~DESC
        Update descriptive metadata on a Work. Either supply a `binary`
        MODS XML upload or `metadata[*]` form fields to merge in.

        Programmatic Delegate writes (thumbnail-family URIs, sized image
        derivatives) no longer ride this endpoint — see the dedicated
        `PATCH /works/{id}/thumbnails` and `PATCH /works/{id}/image_derivatives`
        routes.
      DESC
      parameter name: 'metadata[title]',         in: :formData, required: false
      parameter name: 'metadata[description]',   in: :formData, required: false
      parameter name: :binary,                   in: :formData, required: false
      multipart_request_body(
        {
          'metadata[title]':         { type: :string },
          'metadata[description]':   { type: :string },
          binary: { type: :string, format: :binary, description: 'MODS XML to apply to the Work' }
        }
      )

      response '200', 'work updated' do
        let(:work)              { WorkCreator.call(parent_id: collection.noid) }
        let(:id)                { work.noid }
        let(:'metadata[title]') { 'Updated' }
        schema '$ref' => '#/components/schemas/Work'
        run_test!
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
        let(:work) { WorkCreator.call(parent_id: collection.noid) }
        let(:id)   { work.noid }
        schema '$ref' => '#/components/schemas/WorkAssets'
        run_test!
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
          uses = assets.map { |a| a['use'] }.compact
          expect(uses).to include(Role.service_file.name)
          expect(uses).not_to include(Role.thumbnail_image.name)
        end
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
        type: :object,
        properties: {
          thumbnail: { type: :string, description: 'IIIF URL for the 85px thumbnail tier' },
          thumbnail_2x: { type: :string, description: 'IIIF URL for the 170px retina thumbnail tier' },
          preview: { type: :string, description: 'IIIF URL for the 500px hero preview tier' }
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
          members  = Atlas.query.find_members(resource: deriv_fs).to_a
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
            thumbnail: 'https://iiif.example/iiif/3/abc.jp2/full/!85,85/0/default.jpg',
            thumbnail_2x: 'https://iiif.example/iiif/3/abc.jp2/full/!170,170/0/default.jpg',
            preview: 'https://iiif.example/iiif/3/abc.jp2/full/500,/0/default.jpg'
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
        type: :object,
        properties: {
          small: { type: :string, description: 'IIIF URL for the small image tier' },
          medium: { type: :string, description: 'IIIF URL for the medium image tier' },
          large: { type: :string, description: 'IIIF URL for the large image tier' }
        }
      }

      response '200', 'all three image-derivative keys land in one PATCH' do
        let(:work) { WorkCreator.call(parent_id: collection.noid) }
        let(:id) { work.noid }
        let(:body) do
          {
            small: 'https://iiif.example/iiif/3/abc.jp2/full/800,/0/default.jpg',
            medium: 'https://iiif.example/iiif/3/abc.jp2/full/1600,/0/default.jpg',
            large: 'https://iiif.example/iiif/3/abc.jp2/full/full/0/default.jpg'
          }
        end
        schema '$ref' => '#/components/schemas/Work'
        run_test! do
          reloaded = Work.find(work.noid)
          deriv_fs = reloaded.children.find { |c| c.is_a?(FileSet) && c.type == Classification.derivative.name }
          members = Atlas.query.find_members(resource: deriv_fs).to_a.select { |m| m.is_a?(Delegate) }
          uris_by_use = members.to_h { |m| [m.use, m.uri] }
          expect(uris_by_use).to eq(
            Role.small_image.name => 'https://iiif.example/iiif/3/abc.jp2/full/800,/0/default.jpg',
            Role.medium_image.name => 'https://iiif.example/iiif/3/abc.jp2/full/1600,/0/default.jpg',
            Role.large_image.name => 'https://iiif.example/iiif/3/abc.jp2/full/full/0/default.jpg'
          )
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
    end
  end
end
