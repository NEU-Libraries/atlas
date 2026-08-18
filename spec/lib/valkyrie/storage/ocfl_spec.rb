# frozen_string_literal: true

require 'rails_helper'
require 'valkyrie/specs/shared_specs'

# The upstream shared spec calls WebMock.disable!/enable! and shells out to
# `lsof +D .`. Atlas doesn't carry WebMock and the container has no lsof, so
# we provide minimal no-op shims rather than adding a system dependency.
unless defined?(WebMock)
  module WebMock
    def self.disable!; end
    def self.enable!; end
  end
end

RSpec.describe Valkyrie::Storage::OCFL do
  before do
    # Override the shared spec's `open_files` (which uses lsof) per-example.
    define_singleton_method(:open_files) { [] }
  end

  let(:tmpdir) { Dir.mktmpdir('ocfl-spec-') }
  after { FileUtils.rm_rf(tmpdir) }

  let(:storage_adapter) do
    described_class.new(
      storage_root: tmpdir,
      file_mover:   FileUtils.method(:mv),
      clock:        -> { Time.utc(2026, 1, 1) }
    )
  end

  # Copy example.bin to a per-example Tempfile so file_mover: :mv doesn't
  # destroy the source fixture across tests in the shared spec.
  let(:file) do
    tmp = Tempfile.new(['ocfl-fixture-', '.bin'])
    IO.copy_stream(Rails.root.join('spec/fixtures/files/example.bin').to_s, tmp)
    tmp.rewind
    tmp
  end

  # A second fixture with different bytes, so two uploads to one object produce
  # two genuinely different content digests.
  let(:other_file) do
    tmp = Tempfile.new(['ocfl-fixture-', '.png'])
    IO.copy_stream(Rails.root.join('spec/fixtures/files/example.png').to_s, tmp)
    tmp.rewind
    tmp
  end

  let(:noid_resource) do
    Class.new(Valkyrie::Resource) do
      attribute :noid, Valkyrie::Types::String
    end.new(noid: 'abcd1234e')
  end

  let(:upload!) do
    lambda do |io = file, original_filename: 'foo.jpg', resource: noid_resource|
      storage_adapter.upload(file: io, original_filename: original_filename, resource: resource)
    end
  end

  it_behaves_like 'a Valkyrie::StorageAdapter'

  describe 'OCFL on-disk layout' do
    it 'writes storage-root NAMASTE + ocfl_layout.json + extension config' do
      upload!.call
      expect(File.read(File.join(tmpdir, '0=ocfl_1.1'))).to eq("ocfl_1.1\n")
      expect(File).to exist(File.join(tmpdir, 'ocfl_layout.json'))
      expect(File).to exist(File.join(tmpdir, 'extensions',
                                      '0007-n-tuple-omit-prefix-storage-layout', 'config.json'))
    end

    it 'writes object NAMASTE + head inventory + sidecar after upload' do
      upload!.call
      object_root = File.join(tmpdir, 'ab', 'cd', 'abcd1234e')
      expect(File.read(File.join(object_root, '0=ocfl_object_1.1'))).to eq("ocfl_object_1.1\n")
      expect(File).to exist(File.join(object_root, 'inventory.json'))
      expect(File).to exist(File.join(object_root, 'inventory.json.sha512'))
    end

    it 'writes content under v1/content/' do
      upload!.call
      object_root = File.join(tmpdir, 'ab', 'cd', 'abcd1234e')
      expect(File).to exist(File.join(object_root, 'v1', 'content', 'foo.jpg'))
      expect(File).to exist(File.join(object_root, 'v1', 'inventory.json'))
      expect(File).to exist(File.join(object_root, 'v1', 'inventory.json.sha512'))
    end

    it 'lays NOIDs out per extension 0007 with tuple (2,2)' do
      upload!.call
      expect(Dir).to exist(File.join(tmpdir, 'ab', 'cd', 'abcd1234e'))
    end

    it 'reuses an existing manifest digest on duplicate upload (dedup)' do
      first = upload!.call
      tmp2 = Tempfile.new(['ocfl-fixture-', '.bin'])
      IO.copy_stream(Rails.root.join('spec/fixtures/files/example.bin').to_s, tmp2)
      tmp2.rewind
      second = storage_adapter.upload_version(id: first.id, file: tmp2)

      object_root = File.join(tmpdir, 'ab', 'cd', 'abcd1234e')
      inventory = JSON.parse(File.read(File.join(object_root, 'inventory.json')))
      expect(inventory['manifest'].size).to eq(1)
      expect(File).not_to exist(File.join(object_root, 'v2', 'content', 'foo.jpg'))
      expect(second.version_id).not_to eq(first.version_id)
    end

    it 'records inventory id as urn:neu-drs:<noid> per OCFL W005' do
      upload!.call
      object_root = File.join(tmpdir, 'ab', 'cd', 'abcd1234e')
      inventory = JSON.parse(File.read(File.join(object_root, 'inventory.json')))
      expect(inventory['id']).to eq('urn:neu-drs:abcd1234e')
    end

    it 'self-validates: every manifest digest matches the on-disk content sha512' do
      upload!.call
      object_root = File.join(tmpdir, 'ab', 'cd', 'abcd1234e')
      inventory = JSON.parse(File.read(File.join(object_root, 'inventory.json')))
      inventory['manifest'].each do |digest, paths|
        paths.each do |p|
          expect(Digest::SHA512.file(File.join(object_root, p)).hexdigest).to eq(digest)
        end
      end
    end
  end

  describe 'logical path portability' do
    def fresh_io
      tmp = Tempfile.new(['ocfl-fixture-', '.bin'])
      IO.copy_stream(Rails.root.join('spec/fixtures/files/example.bin').to_s, tmp)
      tmp.rewind
      tmp
    end

    # The head id ends in the logical path, so its last segment is what the
    # sanitiser produced.
    def logical_path_for(original_filename)
      storage_adapter.upload(file: fresh_io, original_filename: original_filename,
                             resource: noid_resource).id.to_s.split('/').last
    end

    it 'flattens a directory component so a deposit cannot escape its object' do
      expect(logical_path_for('../../etc/passwd')).to eq('passwd')
      expect(logical_path_for('scans/page.tif')).to eq('page.tif')
      expect(logical_path_for('C:\Users\x\report.pdf')).to eq('report.pdf')
    end

    it 'replaces the characters an SMB-backed mount rejects' do
      expect(logical_path_for('a:b*c?d.txt')).to eq('a_b_c_d.txt')
    end

    it 'drops a trailing dot or space' do
      expect(logical_path_for('report.pdf. ')).to eq('report.pdf')
    end

    it 'sidesteps a reserved device name and keeps the extension' do
      expect(logical_path_for('con.txt')).to eq('_con.txt')
    end

    it 'keeps non-ASCII, normalised to NFC' do
      expect(logical_path_for("cafe\u0301.txt")).to eq("caf\u00e9.txt")
    end

    it 'trims an over-long name and keeps the extension' do
      result = logical_path_for("#{'x' * 400}.tif")
      expect(result.bytesize).to be <= 200
      expect(result).to end_with('.tif')
    end

    it 'falls back to "file" when nothing usable remains' do
      expect(logical_path_for('..')).to eq('file')
    end
  end

  describe 'write durability' do
    let(:object_root) { File.join(tmpdir, 'ab', 'cd', 'abcd1234e') }

    it 'fsyncs the staged version tree and the object root before returning' do
      synced = []
      allow_any_instance_of(File).to receive(:fsync) { |handle| synced << handle.path }

      upload!.call

      expect(synced).to include(a_string_matching(%r{/\.tmp-v1-\h+/content/foo\.jpg\z}))
      expect(synced).to include(a_string_matching(%r{/\.tmp-v1-\h+/inventory\.json\z}))
      expect(synced).to include(a_string_matching(%r{/\.tmp-v1-\h+\z}))
      expect(synced).to include(a_string_matching(%r{/tmp_inventory\.json\z}))
      # Once after the version directory is published, once after the head pair.
      expect(synced.count(object_root)).to eq(2)
    end
  end

  describe '#find_version_metadata_for' do
    it 'reports created and digest per id, each read at its own version' do
      first  = upload!.call
      second = upload!.call(other_file)

      facts = storage_adapter.find_version_metadata_for(ids: [first.version_id, second.version_id])
      expect(facts.keys).to contain_exactly(first.version_id.to_s, second.version_id.to_s)
      expect(facts.values.pluck(:version)).to contain_exactly('v1', 'v2')
      expect(facts.values.pluck(:created)).to all(be_present)
      expect(facts[first.version_id.to_s][:digest])
        .not_to eq(facts[second.version_id.to_s][:digest])
    end

    # The case the head-keyed lookup got wrong: a replacement lands under the
    # name of the file that was uploaded, so the superseded revision's logical
    # path is not the current one.
    it 'reports a superseded revision whose logical path is no longer current' do
      first  = upload!.call(file, original_filename: 'deposited.bin')
      second = upload!.call(other_file, original_filename: 'RackMultipart-1234.tmp')

      facts = storage_adapter.find_version_metadata_for(ids: [first.version_id, second.version_id])
      expect(facts[first.version_id.to_s][:created]).to be_present
      expect(facts[first.version_id.to_s][:digest]).to be_present
    end

    it 'resolves an unversioned id at the head version' do
      upload!.call
      second = upload!.call(other_file)

      facts = storage_adapter.find_version_metadata_for(ids: [second.id])
      expect(facts[second.id.to_s][:version]).to eq('v2')
    end

    it 'omits ids it cannot resolve and returns {} for none' do
      first = upload!.call

      facts = storage_adapter.find_version_metadata_for(
        ids: [first.version_id, "#{first.id.to_s.sub(%r{/foo\.jpg\z}, '')}/v99/foo.jpg", 'file:///elsewhere']
      )
      expect(facts.keys).to eq([first.version_id.to_s])
      expect(storage_adapter.find_version_metadata_for(ids: [])).to eq({})
    end
  end
end
