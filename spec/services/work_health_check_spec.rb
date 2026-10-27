# frozen_string_literal: true

require 'rails_helper'

RSpec.describe WorkHealthCheck do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:work) do
    WorkCreator.call(parent_id: collection.noid, depositor: '000000099',
                     mods_xml: Rails.root.join('spec/fixtures/files/work-mods.xml').read)
  end
  let!(:blob) do
    source = Rails.root.join('tmp', "health-#{SecureRandom.hex(4)}.png")
    FileUtils.cp(Rails.root.join('spec/fixtures/files/example.png'), source)
    BlobCreator.call(path: source.to_s, work_id: work.noid, original_filename: 'example.png')
  end

  def report(fixity: false)
    described_class.call(noid: work.noid, fixity: fixity)
  end

  def codes(result = report)
    result[:findings].reject { |f| f[:severity] == :advisory }.map { |f| f[:code] }
  end

  def reload(resource) = Resource.find(resource.noid)
  def save(resource) = Atlas.persister.save(resource: resource)

  it 'grades a freshly deposited Work green' do
    expect(report[:grade]).to eq(:green)
  end

  # A finalized Work in production has both, and each once graded it yellow.
  it 'grades a Work with derivatives and a minted handle green' do
    DelegateCreator.call(resource_id: work.id, use: Role.thumbnail_image.name, uri: 'https://iiif.example/thumb.jpg')
    client = instance_double(HandleClient, configured?: true, mint: "DRSDEV/#{work.noid}")
    HandleMinter.call(work: work, client: client, public_base: 'https://repository.example.edu')

    expect(reload(work).handle).to eq("DRSDEV/#{work.noid}")
    expect(report[:findings]).to be_empty.or(all(include(severity: :advisory)))
    expect(report[:grade]).to eq(:green)
  end

  it 'answers red for a NOID Postgres does not hold' do
    expect(described_class.call(noid: 'zzzzzzzzz')).to include(grade: :red)
  end

  describe 'yellow: viable once repaired, nothing lost' do
    it 'flags a Work with no title' do
      work.mods_xml = Rails.root.join('spec/fixtures/files/work-mods.xml').read
                           .sub(%r{<mods:title>[^<]*</mods:title>}, '<mods:title/>')
      save(work)
      expect(codes).to eq([:untitled])
    end

    it 'flags a missing access copy, which the XML can rebuild' do
      Metadata::MODS.where(valkyrie_id: work.noid).delete_all
      expect(codes).to eq([:mods_access_copy_missing])
    end

    it 'flags an orphan' do
      save(reload(work).tap { |w| w.a_member_of = nil })
      expect(codes).to include(:orphaned)
    end

    it 'flags a Work left readable inside a withdrawn Collection' do
      save(reload(collection).tap { |c| c.tombstone(by: 'spec') })
      expect(codes).to eq([:live_under_withdrawn])
    end

    it 'flags an ACL that locks out staff and the depositor' do
      save(reload(work).tap do |w|
        w.edit_groups = []
        w.depositor = nil
      end)
      expect(codes).to include(:staff_edit_missing, :no_depositor)
    end

    it 'flags a Blob that cannot be downloaded for want of a MIME type' do
      save(reload(blob).tap { |b| b.mime_type = nil })
      expect(codes).to include(:blob_metadata_missing)
    end

    it 'flags a Work search cannot find' do
      RSolr.connect(url: SolrCore.url).tap do |solr|
        solr.delete_by_query("alternate_ids_ssim:\"id-#{work.noid}\"")
        solr.commit
      end
      expect(codes).to eq([:not_indexed])
    end
  end

  describe 'red: bytes are lost' do
    let(:pool) { OcflHealth::Pool.new([TestStorage.root]) }

    it 'flags a binary gone from storage' do
      FileUtils.rm_rf(pool.object_path(blob.noid))
      expect(report[:grade]).to eq(:red)
      expect(codes).to include(:binary_missing)
    end

    it 'flags altered bytes, but only when asked to re-hash them' do
      File.write(reload(blob).path, 'not a png')
      expect(report[:grade]).to eq(:green)
      expect(codes(report(fixity: true))).to include(:fixity_mismatch)
    end

    it 'flags MODS XML gone from storage, though every read still answers' do
      FileUtils.rm_rf(pool.object_path(work.mods_blob.noid))
      expect(codes).to include(:mods_xml_missing)
    end
  end

  describe 'the fixity summary' do
    def objects = reload(work).preserved_resources.map(&:noid)

    def checked(key, at, result)
      FixityResult.advance!(key: key, checked_at: at, result: result, version: 'v1', checker: 'spec')
    end

    it 'reports every object as never checked before any check is recorded' do
      expect(report[:fixity]).to eq(last_checked_at: nil, result: nil, objects: objects.size,
                                    never_checked: objects.size)
    end

    # A Work is only as verified as its least recently checked part.
    it 'reports the oldest latest check and the worst outcome' do
      keys = objects
      keys.each_with_index { |key, i| checked(key, Time.utc(2026, 10, 1 + i), 'pass') }
      checked(keys.last, Time.utc(2026, 10, 20), 'fail')

      expect(report[:fixity]).to eq(last_checked_at: '2026-10-01T00:00:00Z', result: 'fail',
                                    objects: keys.size, never_checked: 0)
    end

    it 'grades red on an object whose latest check failed, and green again once a re-check passes' do
      blob_key = reload(work).preserved_resources.last.noid
      checked(blob_key, Time.utc(2026, 10, 1), 'fail')

      expect(report[:grade]).to eq(:red)
      expect(report[:findings]).to include(include(severity: :fatal, code: :fixity_failed, subject: blob_key))

      checked(blob_key, Time.utc(2026, 10, 2), 'pass')
      expect(codes).not_to include(:fixity_failed)
    end

    it 'leaves last_checked_at null while any object is unchecked' do
      checked(work.noid, Time.utc(2026, 10, 1), 'pass')

      expect(report[:fixity]).to include(last_checked_at: nil, result: 'pass', never_checked: objects.size - 1)
    end
  end
end
