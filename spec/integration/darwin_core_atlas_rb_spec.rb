# frozen_string_literal: true

require 'rails_helper'

# atlas_rb's Darwin Core bindings end to end through the live server: the
# multipart upload, the three read kinds, the error mapping each write takes,
# and the history pair. See docs/metadata-records.md.
RSpec.describe 'Darwin Core records via atlas_rb', :atlas_rb_server do
  let(:admin_nuid) { ATLAS_RB_SERVER_ADMIN_NUID }
  let(:archives)   { 'northeastern:drs:library:archives' }

  # A real person with no grant on anything below.
  let!(:outsider) do
    User.create!(email: 'dwc-reader-int@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000005', name: 'Student, Sam', role: :standard,
                 groups: ['northeastern:drs:library:dsg_students'])
  end

  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work)       { WorkCreator.call(parent_id: collection.noid) }

  let(:dwc_path)    { fixture('dwc.xml') }
  let(:other_path)  { fixture('dwc-other.xml') }
  let(:broken_path) { fixture('dwc-tdwg-example-broken.xml') }

  def fixture(name)
    Rails.root.join('spec/fixtures/files', name).to_s
  end

  def put_dwc(path = dwc_path, **)
    AtlasRb::Resource.put_dwc(work.noid, path, nuid: admin_nuid, **)
  end

  def metadata_formats
    AtlasRb::Work.find(work.noid, nuid: admin_nuid)['metadata_formats']
  end

  describe 'writing and reading the record' do
    it 'answers the write with the projected terms, and advertises the format' do
      expect(metadata_formats).to eq([])

      written = put_dwc
      expect(written['id']).to eq(work.noid)
      expect(written['dwc']['catalogNumber']).to eq('MVZ:Mamm:14523')
      expect(metadata_formats).to eq(['dwc'])
    end

    it 'reads the record in each of the three kinds' do
      put_dwc

      expect(AtlasRb::Work.dwc(work.noid, nuid: admin_nuid)).to eq(File.read(dwc_path))
      expect(AtlasRb::Work.dwc(work.noid, 'json', nuid: admin_nuid)['dwc'])
        .to include('scientificName' => 'Perognathus inornatus inornatus')
      expect(AtlasRb::Work.dwc(work.noid, 'html', nuid: admin_nuid))
        .to include('data-term="catalogNumber"', 'Catalog Number')
    end

    it 'reads nil for a Work with no record and for an id that is not a Work' do
      expect(AtlasRb::Work.dwc(work.noid, nuid: admin_nuid)).to be_nil
      expect(AtlasRb::Work.dwc(collection.noid, 'json', nuid: admin_nuid)).to be_nil
    end

    # The shared multipart helper carries `origin` for put_mods too; this is
    # the Darwin Core half of edit_origin_atlas_rb_spec.rb.
    it 'records the origin beside the dwc source on the audit event' do
      put_dwc(origin: 'xml_loader')

      event = AtlasRb::Resource.history(work.noid, nuid: admin_nuid)['events']
                               .find { |e| e['change_type'] == 'metadata' && e.dig('payload', 'source') == 'dwc' }
      expect(event).to include('action' => 'update', 'actor_nuid' => admin_nuid)
      expect(event['payload']).to include('origin' => 'xml_loader')
    end
  end

  describe 'a refused write' do
    # No middleware claims /dwc, so the 422 envelope must reach the caller
    # intact rather than as a translated error or a parse failure.
    it 'raises ResourceError carrying the 422 and the rule it broke' do
      expect { put_dwc(broken_path) }.to raise_error(AtlasRb::ResourceError) do |error|
        expect(error.status).to eq(422)
        expect(JSON.parse(error.body)['error']).to eq('malformed_xml')
      end
      expect(metadata_formats).to eq([])
    end

    it 'raises NotFoundError for an id that is not a Work' do
      expect { AtlasRb::Resource.put_dwc(collection.noid, dwc_path, nuid: admin_nuid) }
        .to raise_error(AtlasRb::NotFoundError)
    end
  end

  describe 'withdrawing and restoring the record' do
    before { put_dwc }

    it 'withdraws without purging, and the next write restores it' do
      expect(AtlasRb::Resource.delete_dwc(work.noid, nuid: admin_nuid)).to be(true)
      expect(AtlasRb::Work.dwc(work.noid, nuid: admin_nuid)).to be_nil
      expect(metadata_formats).to eq([])

      put_dwc(other_path)
      expect(AtlasRb::Work.dwc(work.noid, 'json', nuid: admin_nuid)['dwc']['catalogNumber'])
        .to eq('MVZ:Mamm:14524')
      expect(AtlasRb::Resource.dwc_versions(work.noid, nuid: admin_nuid)['versions'].length).to eq(2)
    end

    it 'raises NotFoundError when there is nothing to withdraw' do
      AtlasRb::Resource.delete_dwc(work.noid, nuid: admin_nuid)

      expect { AtlasRb::Resource.delete_dwc(work.noid, nuid: admin_nuid) }
        .to raise_error(AtlasRb::NotFoundError)
    end
  end

  describe 'the version history' do
    it 'lists the versions newest first, and fetches each one as XML' do
      put_dwc
      put_dwc(other_path)

      envelope = AtlasRb::Resource.dwc_versions(work.noid, nuid: admin_nuid)
      expect(envelope['resource_id']).to eq(work.noid)
      versions = envelope['versions']
      expect(versions.pluck('source')).to all(eq('dwc'))
      expect(versions.first['actor_nuid']).to eq(admin_nuid)

      expect(AtlasRb::Resource.dwc_version(work.noid, versions.first['version_id'], nuid: admin_nuid))
        .to eq(File.read(other_path))
      expect(AtlasRb::Resource.dwc_version(work.noid, versions.last['version_id'], nuid: admin_nuid))
        .to eq(File.read(dwc_path))
    end

    it 'reads nil for an unknown version' do
      put_dwc
      expect(AtlasRb::Resource.dwc_version(work.noid, 'v9999', nuid: admin_nuid)).to be_nil
    end
  end

  describe 'the gates' do
    let(:restricted_work) do
      restricted_community = CommunityCreator.call
      restricted_community.read_groups = [archives]
      restricted_community = Atlas.persister.save(resource: restricted_community)

      child = CollectionCreator.call(parent_id: restricted_community.noid)
      child.permissions = { read: [archives], edit: [archives], edit_users: [] }
      WorkCreator.call(parent_id: Atlas.persister.save(resource: child).noid)
    end

    it 'raises ResourceError carrying the 403 for a Work the caller may not read' do
      AtlasRb::Resource.put_dwc(restricted_work.noid, dwc_path, nuid: admin_nuid)

      expect { AtlasRb::Work.dwc(restricted_work.noid, 'html', nuid: outsider.nuid) }
        .to raise_error(AtlasRb::ResourceError) { |error| expect(error.status).to eq(403) }
    end

    it 'raises ResourceError carrying the 403 from the admin-gated history' do
      put_dwc

      expect { AtlasRb::Resource.dwc_versions(work.noid, nuid: outsider.nuid) }
        .to raise_error(AtlasRb::ResourceError) { |error| expect(error.status).to eq(403) }
    end
  end
end
