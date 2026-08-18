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

  let(:other_resource) do
    Class.new(Valkyrie::Resource) do
      attribute :noid, Valkyrie::Types::String
    end.new(noid: 'wxyz9876f')
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

  describe 'a pool of storage roots' do
    let(:other_tmpdir) { Dir.mktmpdir('ocfl-spec-b-') }
    after { FileUtils.rm_rf(other_tmpdir) }

    # Same tag and same two roots each time; only the order differs, and the
    # first entry is the default a write lands in.
    def pool(order = %w[r001 r002], clock: Time.utc(2026, 1, 1))
      paths = { 'r001' => tmpdir, 'r002' => other_tmpdir }
      described_class.new(
        storage_roots: order.index_with { |n| paths.fetch(n) },
        tag:           'pooltag',
        file_mover:    FileUtils.method(:mv),
        clock:         -> { clock }
      )
    end

    def object_dir(dir)
      Pathname.new(dir).join('ab', 'cd', 'abcd1234e')
    end

    it 'reads an object out of the root its id names' do
      stored = pool(%w[r002 r001]).upload(file: file, original_filename: 'foo.jpg', resource: noid_resource)

      expect(stored.id.to_s).to eq('ocfl://pooltag/@r002/abcd1234e/foo.jpg')
      expect(object_dir(other_tmpdir)).to exist
      expect(object_dir(tmpdir)).not_to exist
      # The reader's own default is 'r001'; it finds the object because the id says 'r002'.
      expect(pool.find_by(id: stored.id).version_id).to eq(stored.version_id)
      expect(pool.find_versions(id: stored.id).length).to eq(1)
      expect(pool.digest_for(id: stored.id)[:value]).to be_present
    end

    it 'declines an id naming a root the pool does not hold' do
      pool.upload(file: file, original_filename: 'foo.jpg', resource: noid_resource)
      foreign = 'ocfl://pooltag/@zz/abcd1234e/foo.jpg'

      expect { pool.find_by(id: foreign) }.to raise_error(Valkyrie::StorageAdapter::FileNotFound)
      expect(pool.find_versions(id: foreign)).to eq([])
      expect(pool.digest_for(id: foreign)).to be_nil
    end

    it 'reads version metadata from each id own root, not from one of them' do
      in_a = pool(%w[r001 r002], clock: Time.utc(2026, 1, 1))
             .upload(file: file, original_filename: 'foo.jpg', resource: noid_resource)
      in_b = pool(%w[r002 r001], clock: Time.utc(2026, 2, 2))
             .upload(file: other_file, original_filename: 'foo.jpg', resource: noid_resource)

      facts = pool.find_version_metadata_for(ids: [in_a.version_id, in_b.version_id])

      expect(facts.keys).to contain_exactly(in_a.version_id.to_s, in_b.version_id.to_s)
      expect(facts[in_a.version_id.to_s][:created]).to eq('2026-01-01T00:00:00Z')
      expect(facts[in_b.version_id.to_s][:created]).to eq('2026-02-02T00:00:00Z')
      expect(facts[in_a.version_id.to_s][:digest]).not_to eq(facts[in_b.version_id.to_s][:digest])
    end

    it 'sends a new object to the open root, and the next one on after a seal' do
      adapter = pool
      first = adapter.upload(file: file, original_filename: 'foo.jpg', resource: noid_resource)
      expect(first.id.to_s).to include('/@r001/')

      adapter.seal!('r001', reason: 'full')
      expect(adapter).to be_sealed('r001')
      expect(adapter.open_root_name).to eq('r002')

      second = adapter.upload(file: other_file, original_filename: 'bar.png', resource: other_resource)
      expect(second.id.to_s).to include('/@r002/')
    end

    it 'keeps taking new versions of the objects a sealed root already holds' do
      adapter = pool
      first = adapter.upload(file: file, original_filename: 'foo.jpg', resource: noid_resource)
      adapter.seal!('r001')

      again = adapter.upload_version(id: first.id, file: other_file)

      expect(again.id).to eq(first.id)
      expect(again.version_id.to_s).to eq('ocfl://pooltag/@r001/abcd1234e/v2/foo.jpg')
      expect(adapter.find_versions(id: first.id).length).to eq(2)
    end

    it 'never lets one object span two roots, even when its root is sealed' do
      adapter = pool
      adapter.upload(file: file, original_filename: 'foo.jpg', resource: noid_resource)
      adapter.seal!('r001')

      # A second logical path for the SAME resource is the same OCFL object, so
      # placement must not send it to the open root.
      sibling = adapter.upload(file: other_file, original_filename: 'sidecar.xml', resource: noid_resource)

      expect(sibling.id.to_s).to eq('ocfl://pooltag/@r001/abcd1234e/sidecar.xml')
      expect(object_dir(other_tmpdir)).not_to exist
    end

    it 'refuses to place a new object when every root is sealed' do
      adapter = pool
      adapter.seal!('r001')
      adapter.seal!('r002')

      expect { adapter.open_root_name }
        .to raise_error(described_class::PoolSealed, /every storage root is sealed/)
      expect { adapter.upload(file: file, original_filename: 'foo.jpg', resource: noid_resource) }
        .to raise_error(described_class::PoolSealed)
    end

    it 'refuses to guess when one key exists in two roots' do
      adapter = pool
      adapter.upload(file: file, original_filename: 'foo.jpg', resource: noid_resource)
      # Only a botched migration outside the adapter reaches this state:
      # placement itself always sends a later write to the root already holding
      # the object, which is why it has to be staged by hand here.
      FileUtils.mkdir_p(object_dir(other_tmpdir).dirname)
      FileUtils.cp_r(object_dir(tmpdir).to_s, object_dir(other_tmpdir).to_s)

      expect { adapter.upload(file: other_file, original_filename: 'foo.jpg', resource: noid_resource) }
        .to raise_error(described_class::AmbiguousObject, /more than one storage root/)
    end

    it 'removes an object from whichever root holds it' do
      adapter = pool
      adapter.seal!('r001')
      stored = adapter.upload(file: file, original_filename: 'foo.jpg', resource: noid_resource)
      expect(object_dir(other_tmpdir)).to exist

      # delete_object is given a NOID, which names no root, so it has to search.
      adapter.delete_object(key: 'abcd1234e')

      expect(object_dir(other_tmpdir)).not_to exist
      expect { adapter.find_by(id: stored.id) }.to raise_error(Valkyrie::StorageAdapter::FileNotFound)
    end

    it 'shrugs off a NOID no root holds' do
      expect { pool.delete_object(key: 'nosuchnoid') }.not_to raise_error
    end

    it 'refuses to remove a key that two roots hold' do
      adapter = pool
      adapter.upload(file: file, original_filename: 'foo.jpg', resource: noid_resource)
      FileUtils.mkdir_p(object_dir(other_tmpdir).dirname)
      FileUtils.cp_r(object_dir(tmpdir).to_s, object_dir(other_tmpdir).to_s)

      expect { adapter.delete_object(key: 'abcd1234e') }
        .to raise_error(described_class::AmbiguousObject)
      expect(object_dir(tmpdir)).to exist
      expect(object_dir(other_tmpdir)).to exist
    end

    def descriptor(dir)
      JSON.parse(Pathname.new(dir).join('extensions', 'neu-drs-storage-pool', 'config.json').read)
    end

    it 'records the pool inside each root it writes to' do
      adapter = pool
      adapter.upload(file: file, original_filename: 'foo.jpg', resource: noid_resource)
      adapter.seal!('r001')
      adapter.upload(file: other_file, original_filename: 'bar.png', resource: other_resource)

      expect(descriptor(tmpdir)).to include('pool' => 'drs', 'root' => 'r001', 'siblings' => ['r002'])
      expect(descriptor(other_tmpdir)).to include('pool' => 'drs', 'root' => 'r002', 'siblings' => ['r001'])
      expect(descriptor(tmpdir)['written']).to eq('2026-01-01T00:00:00Z')
    end

    it 'heals the sibling list when the pool grows' do
      described_class.new(storage_root: tmpdir, tag: 'pooltag', file_mover: FileUtils.method(:mv),
                          clock: -> { Time.utc(2026, 1, 1) })
                     .upload(file: file, original_filename: 'foo.jpg', resource: noid_resource)
      expect(descriptor(tmpdir)['siblings']).to eq([])

      pool.upload(file: other_file, original_filename: 'bar.png', resource: other_resource)

      expect(descriptor(tmpdir)['siblings']).to eq(['r002'])
    end

    it 'keeps each root a valid OCFL storage root in its own right' do
      adapter = pool
      adapter.seal!('r001')
      adapter.upload(file: file, original_filename: 'foo.jpg', resource: noid_resource)

      [tmpdir, other_tmpdir].each do |dir|
        expect(File.read(File.join(dir, '0=ocfl_1.1'))).to eq("ocfl_1.1\n")
        expect(File).to exist(File.join(dir, 'ocfl_layout.json'))
        expect(File).to exist(File.join(dir, 'extensions',
                                        '0007-n-tuple-omit-prefix-storage-layout', 'config.json'))
      end
    end

    it 'derives a tag from the first root when none is named' do
      adapter = described_class.new(storage_roots: { 'r001' => tmpdir, 'r002' => other_tmpdir })
      expect(adapter.tag).to eq(Digest::SHA1.hexdigest(tmpdir.to_s)[0..7])
    end

    it 'refuses a pool with no path behind a name' do
      expect { described_class.new(storage_roots: { 'r001' => nil }) }
        .to raise_error(ArgumentError, /storage_root/)
      expect { described_class.new(storage_roots: { 'r001' => '' }) }
        .to raise_error(ArgumentError, /storage_root/)
      expect { described_class.new }.to raise_error(ArgumentError, /storage_root/)
    end

    # Config passes Pathnames while these specs pass Strings, and a Pathname
    # answers blank? by asking whether its directory is empty on disk. An empty
    # root is what every fresh mount looks like.
    it 'accepts a Pathname root that exists and is empty' do
      expect(Pathname.new(tmpdir)).to be_empty

      adapter = described_class.new(storage_root: Pathname.new(tmpdir), tag: 'pathname')

      expect(adapter.storage_roots.keys).to eq(['r001'])
      expect(adapter.open_root_name).to eq('r001')
      stored = adapter.upload(file: file, original_filename: 'foo.jpg', resource: noid_resource)
      expect(adapter.find_by(id: stored.id).version_id).to eq(stored.version_id)
    end
  end

  describe 'the root segment in an id' do
    it 'names the root in both id forms' do
      stored = upload!.call
      expect(stored.id.to_s).to eq("ocfl://#{storage_adapter.tag}/@r001/abcd1234e/foo.jpg")
      expect(stored.version_id.to_s).to eq("ocfl://#{storage_adapter.tag}/@r001/abcd1234e/v1/foo.jpg")
    end

    it 'round-trips a rooted id through find_by and find_versions' do
      stored = upload!.call
      expect(storage_adapter.find_by(id: stored.id).version_id).to eq(stored.version_id)
      expect(storage_adapter.find_by(id: stored.version_id).version_id).to eq(stored.version_id)
      expect(storage_adapter.find_versions(id: stored.id).map { |f| f.version_id.to_s })
        .to eq([stored.version_id.to_s])
    end

    it 'still resolves an id minted before the segment existed' do
      upload!.call
      legacy = "ocfl://#{storage_adapter.tag}/abcd1234e/foo.jpg"
      expect(storage_adapter.handles?(id: legacy)).to be(true)
      # The handle carries the current form: the segment is read-time insurance,
      # not a shape we keep minting.
      expect(storage_adapter.find_by(id: legacy).id.to_s).to eq("ocfl://#{storage_adapter.tag}/@r001/abcd1234e/foo.jpg")
    end

    it 'declines an id naming a root this adapter does not hold' do
      upload!.call
      foreign = "ocfl://#{storage_adapter.tag}/@zz/abcd1234e/foo.jpg"
      expect { storage_adapter.find_by(id: foreign) }
        .to raise_error(Valkyrie::StorageAdapter::FileNotFound)
      expect(storage_adapter.find_versions(id: foreign)).to eq([])
      expect(storage_adapter.digest_for(id: foreign)).to be_nil
    end

    it 'reads the version label out of a rooted id' do
      expect(storage_adapter.version_label_for(upload!.call.version_id)).to eq('v1')
    end

    it 'refuses a root name that would break the grammar' do
      expect { described_class.new(storage_root: tmpdir, root_name: 'a/b') }
        .to raise_error(ArgumentError, /root name/)
      expect { described_class.new(storage_root: tmpdir, root_name: '') }
        .to raise_error(ArgumentError, /root name/)
      expect { described_class.new(storage_roots: { 'ok' => tmpdir, 'b@d' => tmpdir }) }
        .to raise_error(ArgumentError, /root name/)
    end
  end

  describe '#tag' do
    it 'uses an explicitly named tag verbatim' do
      adapter = described_class.new(storage_root: tmpdir, tag: 'named')
      expect(adapter.tag).to eq('named')
      expect(adapter.handles?(id: 'ocfl://named/abcd1234e/foo.jpg')).to be(true)
    end

    it 'derives a tag from the path when none is named' do
      expect(described_class.new(storage_root: tmpdir).tag)
        .to eq(Digest::SHA1.hexdigest(tmpdir.to_s)[0..7])
    end
  end

  describe '#upload_many' do
    it 'commits every file as one version, and answers a handle each' do
      stored = storage_adapter.upload_many(
        files:    [{ file: file, original_filename: 'relationships.json' },
                   { file: other_file, original_filename: 'permissions.json' }],
        resource: noid_resource
      )

      expect(stored.map { |f| f.version_id.to_s }).to all(include('/v1/'))
      expect(stored.map { |f| f.id.to_s.split('/').last }).to eq(%w[relationships.json permissions.json])

      inventory = JSON.parse(File.read(File.join(tmpdir, 'ab', 'cd', 'abcd1234e', 'inventory.json')))
      expect(inventory['versions'].keys).to eq(['v1'])
      expect(inventory['versions']['v1']['state'].values.flatten)
        .to contain_exactly('relationships.json', 'permissions.json')
    end

    it 'writes one content file when two names carry identical bytes' do
      copy = Tempfile.new(['ocfl-fixture-', '.bin'])
      IO.copy_stream(Rails.root.join('spec/fixtures/files/example.bin').to_s, copy)
      copy.rewind

      storage_adapter.upload_many(
        files:    [{ file: file, original_filename: 'a.bin' }, { file: copy, original_filename: 'b.bin' }],
        resource: noid_resource
      )

      object_root = File.join(tmpdir, 'ab', 'cd', 'abcd1234e')
      inventory = JSON.parse(File.read(File.join(object_root, 'inventory.json')))
      expect(inventory['manifest'].size).to eq(1)
      expect(inventory['versions']['v1']['state'].values.flatten).to contain_exactly('a.bin', 'b.bin')
      expect(Dir.glob(File.join(object_root, 'v1', 'content', '*')).length).to eq(1)
    end

    it 'refuses an empty batch rather than cutting an empty version' do
      expect { storage_adapter.upload_many(files: [], resource: noid_resource) }
        .to raise_error(ArgumentError, /at least one file/)
    end
  end

  describe '#version_label_for' do
    it 'reads the version segment from a versioned id' do
      expect(storage_adapter.version_label_for(upload!.call.version_id)).to eq('v1')
    end

    it 'returns nil for a head id, which names no version' do
      expect(storage_adapter.version_label_for(upload!.call.id)).to be_nil
    end

    it 'reads the version even when the logical path holds a slash' do
      id = "ocfl://#{storage_adapter.tag}/abcd1234e/v3/scans/page.tif"
      expect(storage_adapter.version_label_for(id)).to eq('v3')
    end

    it 'returns nil for an id this adapter does not handle' do
      expect(storage_adapter.version_label_for('ocfl://deadbeef/abcd1234e/v1/foo.jpg')).to be_nil
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
