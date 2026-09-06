# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Works via atlas_rb', :atlas_rb_server do
  # Admin (wildcard) — the cheapest principal that satisfies every
  # Ability-gated path under test.
  let(:admin_nuid) { '000000004' }

  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }

  it 'round-trips a Work through the HTTP boundary' do
    created = AtlasRb::Work.create(collection.noid, nuid: admin_nuid)
    expect(created['id']).to be_present

    found = AtlasRb::Work.find(created['id'], nuid: admin_nuid)
    expect(found['id']).to eq(created['id'])
  end

  it 'updates a Work via multipart MODS upload' do
    work = WorkCreator.call(parent_id: collection.noid)

    AtlasRb::Work.update(work.noid, Rails.root.join('spec/fixtures/files/work-mods.xml').to_s, nuid: admin_nuid)

    found = AtlasRb::Work.find(work.noid, nuid: admin_nuid)
    expect(found['title']).to eq("What's New, Episode 1 - How We Respond to Disaster")
  end

  it 'destroys a Work via HTTP' do
    work = WorkCreator.call(parent_id: collection.noid)

    AtlasRb::Admin::Work.destroy(work.noid, confirm: :i_understand, nuid: admin_nuid)
    expect(Work.find(work.noid)).to be_nil
  end

  describe '.assets' do
    it 'returns a polymorphic array of Blob and Delegate entries, with thumbnail-family Delegates filtered out' do
      work    = WorkCreator.call(parent_id: collection.noid)
      fixture = Rails.root.join('spec/fixtures/files/example.bin').to_s

      AtlasRb::Blob.create(work.noid, fixture, 'example.bin', nuid: admin_nuid)
      DelegateCreator.call(resource_id: work.id, use: Role.thumbnail_image.name, uri: 'https://iiif.example/thumb.jpg')
      DelegateCreator.call(resource_id: work.id, use: Role.large_image.name,     uri: 'https://iiif.example/large.jpg')

      assets = AtlasRb::Work.assets(work.noid, nuid: admin_nuid)
      uses   = assets.pluck('use').compact

      # The Blob entry has no `use` in the assets shape; the Delegate
      # entries carry their Role names. Thumbnail Image must NOT appear.
      expect(uses).to     include(Role.large_image.name)
      expect(uses).not_to include(Role.thumbnail_image.name)

      blob_entry = assets.find { |a| a['original_filename'] == 'example.bin' }
      expect(blob_entry).not_to be_nil
      expect(blob_entry['size']).to eq(File.size(fixture))

      # Each asset carries its containing FileSet's classification — the signal a
      # download consumer keys on. example.bin is unidentified => 'File' (generic),
      # which is what Cerberus branches on to zip opaque downloads on the fly.
      expect(blob_entry['classification']).to eq(Classification.generic.name)
      large = assets.find { |a| a['use'] == Role.large_image.name }
      expect(large).to have_key('classification')
    end

    it 'surfaces the per-tier gate (gated / permission) on Delegate entries' do
      work = WorkCreator.call(parent_id: collection.noid)
      work.publicize
      Atlas.persister.save(resource: work)
      DelegateCreator.call(resource_id: work.id, use: Role.small_image.name, uri: 'https://iiif.example/small.jpg')
      DelegateCreator.call(resource_id: work.id, use: Role.large_image.name, uri: 'https://iiif.example/large.jpg')
      DerivativePermissionsUpdater.call(work: Work.find(work.noid), policy: { large: ['northeastern:drs:x:archives'] })

      by_use = AtlasRb::Work.assets(work.noid, nuid: admin_nuid).index_by { |a| a['use'] }
      expect(by_use[Role.small_image.name]['gated']).to be(false)
      expect(by_use[Role.large_image.name]['gated']).to be(true)
      expect(by_use[Role.large_image.name]['permission']).to eq(['northeastern:drs:x:archives'])
    end
  end

  describe '.set_derivative_permissions' do
    it 'stores a per-tier policy and echoes it back on the Work' do
      work = WorkCreator.call(parent_id: collection.noid)
      work.publicize
      Atlas.persister.save(resource: work)

      result = AtlasRb::Work.set_derivative_permissions(
        work.noid,
        policy: { large: ['northeastern:drs:x:archives'], service: ['northeastern:drs:x:archives'] },
        nuid:   admin_nuid
      )
      expect(result['work']['derivative_permissions']['large']).to eq(['northeastern:drs:x:archives'])
      expect(Work.find(work.noid).derivative_gated?(Delegate.new(use: Role.large_image.name))).to be(true)
    end

    it 'gates the master Blob (image original) via the widened vocabulary' do
      work = WorkCreator.call(parent_id: collection.noid)
      work.publicize
      Atlas.persister.save(resource: work)
      file_set = FileSetCreator.call(work_id: work.noid, classification: Classification.image)
      BlobCreator.call(path:              Rails.root.join('spec/fixtures/files/example.png').to_s,
                       file_set_id:       file_set.noid,
                       original_filename: 'master.png')

      AtlasRb::Work.set_derivative_permissions(
        work.noid, policy: { master: ['northeastern:drs:x:archives'] }, nuid: admin_nuid
      )
      master = AtlasRb::Work.assets(work.noid, nuid: admin_nuid).find { |a| a['original_filename'] == 'master.png' }
      expect(master['gated']).to be(true)
      expect(master['permission']).to eq(['northeastern:drs:x:archives'])
    end

    it 'raises the typed DerivativePermissionsError on an invariant violation' do
      work = WorkCreator.call(parent_id: collection.noid)
      work.read_groups = ['northeastern:drs:x:groupA']
      Atlas.persister.save(resource: work)

      expect do
        AtlasRb::Work.set_derivative_permissions(work.noid, policy: { small: ['northeastern:drs:x:groupB'] }, nuid: admin_nuid)
      end.to raise_error(AtlasRb::DerivativePermissionsError) { |e| expect(e.code).to eq('tier_exceeds_resource') }
    end
  end

  describe '.file_sets' do
    it 'returns page FileSets in position order, each with its assets grouped' do
      work = WorkCreator.call(parent_id: collection.noid)
      # created out of order on purpose — position drives the sort
      FileSetCreator.call(work_id: work.noid, classification: Classification.image, position: 2)
      page_one = FileSetCreator.call(work_id: work.noid, classification: Classification.image, position: 1)
      BlobCreator.call(path:              Rails.root.join('spec/fixtures/files/example.bin').to_s,
                       file_set_id:       page_one.noid,
                       original_filename: 'page1.bin')

      pages = AtlasRb::Work.file_sets(work.noid, nuid: admin_nuid)

      expect(pages.pluck('position')).to eq([1, 2])
      expect(pages.first['assets'].pluck('original_filename')).to include('page1.bin')
      expect(pages.pluck('type')).not_to include(Classification.descriptive_metadata.name)
    end
  end

  describe '.mets' do
    it 'serves the page-order projection once the Work is completed' do
      work = WorkCreator.call(parent_id: collection.noid)
      FileSetCreator.call(work_id: work.noid, classification: Classification.image, position: 1)

      AtlasRb::Work.complete(work.noid, nuid: admin_nuid)
      result = AtlasRb::Work.mets(work.noid, nuid: admin_nuid)

      expect(result['id']).to eq(work.noid)
      expect(result['mets']['pages'].pluck('order')).to eq([1])
    end

    it 'returns nil for a Work that has never been completed' do
      work = WorkCreator.call(parent_id: collection.noid)
      expect(AtlasRb::Work.mets(work.noid, nuid: admin_nuid)).to be_nil
    end
  end

  describe '.find — thumbnail-family projections' do
    it 'surfaces thumbnail, thumbnail_2x, and preview on the Work JSON when the Delegates exist' do
      work = WorkCreator.call(parent_id: collection.noid)
      DelegateCreator.call(resource_id: work.id, use: Role.thumbnail_image.name,    uri: 'https://iiif.example/85.jpg')
      DelegateCreator.call(resource_id: work.id, use: Role.thumbnail_image_2x.name, uri: 'https://iiif.example/170.jpg')
      DelegateCreator.call(resource_id: work.id, use: Role.preview_image.name,      uri: 'https://iiif.example/500.jpg')

      found = AtlasRb::Work.find(work.noid, nuid: admin_nuid)
      expect(found['thumbnail']).to    eq('https://iiif.example/85.jpg')
      expect(found['thumbnail_2x']).to eq('https://iiif.example/170.jpg')
      expect(found['preview']).to      eq('https://iiif.example/500.jpg')
    end

    it 'returns null for tiers whose Delegate has not been minted' do
      work = WorkCreator.call(parent_id: collection.noid)
      DelegateCreator.call(resource_id: work.id, use: Role.thumbnail_image.name, uri: 'https://iiif.example/85.jpg')

      found = AtlasRb::Work.find(work.noid, nuid: admin_nuid)
      expect(found['thumbnail']).to    eq('https://iiif.example/85.jpg')
      expect(found['thumbnail_2x']).to be_nil
      expect(found['preview']).to      be_nil
    end
  end

  describe '.set_thumbnails' do
    it 'round-trips the three thumbnail-tier URIs through atlas_rb and surfaces them on the next find' do
      work = WorkCreator.call(parent_id: collection.noid)

      AtlasRb::Work.set_thumbnails(
        work.noid,
        thumbnail:    'https://iiif.example/iiif/3/abc.jp2/full/!85,85/0/default.jpg',
        thumbnail_2x: 'https://iiif.example/iiif/3/abc.jp2/full/!170,170/0/default.jpg',
        preview:      'https://iiif.example/iiif/3/abc.jp2/full/500,/0/default.jpg',
        nuid:         admin_nuid
      )

      found = AtlasRb::Work.find(work.noid, nuid: admin_nuid)
      expect(found['thumbnail']).to eq('https://iiif.example/iiif/3/abc.jp2/full/!85,85/0/default.jpg')
      expect(found['thumbnail_2x']).to eq('https://iiif.example/iiif/3/abc.jp2/full/!170,170/0/default.jpg')
      expect(found['preview']).to eq('https://iiif.example/iiif/3/abc.jp2/full/500,/0/default.jpg')
    end

    it 'upserts in place — repeated calls hold one Delegate per role with the latest URI' do
      work = WorkCreator.call(parent_id: collection.noid)
      uri_v1 = 'https://iiif.example/iiif/3/abc.jp2/full/!85,85/0/default.jpg'
      uri_v2 = 'https://iiif.example/iiif/3/abc.jp2/full/!85,85/0/default.jpg?v2'

      AtlasRb::Work.set_thumbnails(work.noid, thumbnail: uri_v1, nuid: admin_nuid)
      AtlasRb::Work.set_thumbnails(work.noid, thumbnail: uri_v2, nuid: admin_nuid)

      reloaded = Work.find(work.noid)
      deriv_fs = reloaded.children.find { |c| c.is_a?(FileSet) && c.type == Classification.derivative.name }
      members = Atlas.query.find_members(resource: deriv_fs).to_a
                     .select { |m| m.is_a?(Delegate) && m.use == Role.thumbnail_image.name }
      expect(members.size).to eq(1)
      expect(members.first.uri).to eq(uri_v2)
    end

    it 'leaves tiers untouched when their key is omitted' do
      work = WorkCreator.call(parent_id: collection.noid)
      preview_uri = 'https://iiif.example/iiif/3/abc.jp2/full/500,/0/default.jpg'

      AtlasRb::Work.set_thumbnails(work.noid, preview: preview_uri, nuid: admin_nuid)
      AtlasRb::Work.set_thumbnails(work.noid, thumbnail: 'https://iiif.example/iiif/3/abc.jp2/full/!85,85/0/default.jpg', nuid: admin_nuid)

      found = AtlasRb::Work.find(work.noid, nuid: admin_nuid)
      expect(found['preview']).to eq(preview_uri)
      expect(found['thumbnail']).to eq('https://iiif.example/iiif/3/abc.jp2/full/!85,85/0/default.jpg')
    end
  end

  describe '.set_full_text' do
    it 'stores the derived text and makes the Work body-text searchable in Solr' do
      work = WorkCreator.call(parent_id: collection.noid)

      result = AtlasRb::Work.set_full_text(
        work.noid,
        text: 'Running Boston Jon Masters DESCRIPTION: I have a good friend',
        nuid: admin_nuid
      )
      # Returns the Work (the text itself is not echoed — read only through Solr).
      expect(result['work']['id']).to eq(work.noid)

      # Projected onto the Work's Solr doc as the dedicated full_text_tesimv field.
      hits = Atlas.index_adapter.connection.get(
        'select', params: { q: 'full_text_tesimv:Boston', fl: 'id' }
      ).dig('response', 'docs')
      expect(hits.pluck('id')).to include(work.id.to_s)
    end
  end

  describe '.set_image_derivatives' do
    it 'attaches small/medium/large Delegates that surface in .assets' do
      work = WorkCreator.call(parent_id: collection.noid)

      AtlasRb::Work.set_image_derivatives(
        work.noid,
        small:  'https://iiif.example/iiif/3/abc.jp2/full/800,/0/default.jpg',
        medium: 'https://iiif.example/iiif/3/abc.jp2/full/1600,/0/default.jpg',
        large:  'https://iiif.example/iiif/3/abc.jp2/full/full/0/default.jpg',
        nuid:   admin_nuid
      )

      assets = AtlasRb::Work.assets(work.noid, nuid: admin_nuid)
      by_use = assets.to_h { |a| [a['use'], a['uri']] }
      expect(by_use[Role.small_image.name]).to eq('https://iiif.example/iiif/3/abc.jp2/full/800,/0/default.jpg')
      expect(by_use[Role.medium_image.name]).to eq('https://iiif.example/iiif/3/abc.jp2/full/1600,/0/default.jpg')
      expect(by_use[Role.large_image.name]).to eq('https://iiif.example/iiif/3/abc.jp2/full/full/0/default.jpg')
    end

    it 'leaves tiers untouched when their key is omitted' do
      work = WorkCreator.call(parent_id: collection.noid)
      large = 'https://iiif.example/iiif/3/abc.jp2/full/full/0/default.jpg'

      AtlasRb::Work.set_image_derivatives(work.noid, large: large, nuid: admin_nuid)
      AtlasRb::Work.set_image_derivatives(work.noid, small: 'https://iiif.example/iiif/3/abc.jp2/full/800,/0/default.jpg', nuid: admin_nuid)

      assets = AtlasRb::Work.assets(work.noid, nuid: admin_nuid)
      uses = assets.pluck('use').compact
      expect(uses).to contain_exactly(Role.small_image.name, Role.large_image.name)
    end
  end

  # atlas_rb 1.1.1 — `depositor:` kwarg on Work.create (proxy deposit).
  describe '.create with depositor:' do
    it 'stamps the named depositor and records the acting user as proxy_uploader' do
      created = AtlasRb::Work.create(collection.noid, depositor: '900000001', nuid: admin_nuid)

      found = AtlasRb::Work.find(created['id'], nuid: admin_nuid)
      expect(found['depositor']).to      eq('900000001')
      expect(found['proxy_uploader']).to eq(admin_nuid)
    end

    it 'defaults the depositor to the acting user when the kwarg is omitted' do
      created = AtlasRb::Work.create(collection.noid, nuid: admin_nuid)

      found = AtlasRb::Work.find(created['id'], nuid: admin_nuid)
      expect(found['depositor']).to      eq(admin_nuid)
      expect(found['proxy_uploader']).to eq(admin_nuid)
    end
  end

  # atlas_rb's RaiseOnStaleResource middleware translates Atlas's 409
  # `stale_resource` envelope into a typed exception. Pairs with the
  # Atlas-side StaleObjectRetry + 409 rescue_from to cover the optimistic-
  # locking conflict end-to-end over the wire.
  describe 'stale-resource conflict surfaces as AtlasRb::StaleResourceError' do
    it 'raises the typed exception (carrying resource_id + action) when Atlas exhausts its retry budget' do
      work = WorkCreator.call(parent_id: collection.noid)

      # Force every Delegate write to conflict so the controller's retry
      # budget exhausts and Atlas returns the 409 envelope. Stub the
      # backoff sleep so the retry loop doesn't add wall time (same
      # process — the Capybara server thread sees these partial doubles).
      allow_any_instance_of(WorksController).to receive(:sleep)
      allow(DelegateUpdater).to receive(:call).and_raise(Valkyrie::Persistence::StaleObjectError)

      error = nil
      begin
        AtlasRb::Work.set_thumbnails(work.noid, thumbnail: 'https://iiif.example/85.jpg', nuid: admin_nuid)
      rescue AtlasRb::StaleResourceError => e
        error = e
      end

      expect(error).to be_a(AtlasRb::StaleResourceError)
      expect(error.resource_id).to eq(work.noid)
      expect(error.action).to      eq('update_thumbnails')
    end
  end
end
