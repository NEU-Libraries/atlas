# frozen_string_literal: true

require 'rails_helper'

RSpec.describe StorageRootSealer do
  let(:dir_a) { Dir.mktmpdir('sealer-a-') }
  let(:dir_b) { Dir.mktmpdir('sealer-b-') }
  after { FileUtils.rm_rf([dir_a, dir_b]) }

  let(:adapter) do
    Valkyrie::Storage::OCFL.new(
      storage_roots: { 'r001' => dir_a, 'r002' => dir_b },
      tag:           'sealspec',
      file_mover:    FileUtils.method(:cp),
      clock:         -> { Time.utc(2026, 1, 1) }
    )
  end

  let(:fixture) { Rails.root.join('spec/fixtures/files/example.bin').to_s }

  def resource_class
    @resource_class ||= Class.new(Valkyrie::Resource) do
      attribute :noid, Valkyrie::Types::String
    end
  end

  # Deposits `count` distinct objects into whichever root is open.
  def deposit(count)
    count.times do |i|
      adapter.upload(file: File.open(fixture, 'rb'), original_filename: 'foo.bin',
                     resource: resource_class.new(noid: format('obj%05d', i)))
    end
  end

  def seal(**overrides)
    described_class.call(root_name: 'r001', adapter: adapter, **overrides)
  end

  it 'leaves a root open below the limit' do
    deposit(2)

    expect(seal(max_objects: 3)).to include(root: 'r001', objects: 2, sealed: false, reason: nil)
    expect(adapter).not_to be_sealed('r001')
  end

  it 'seals a root that reached the limit, recording the count as the reason' do
    deposit(3)

    expect(seal(max_objects: 3)).to include(objects: 3, sealed: true)
    expect(adapter).to be_sealed('r001')

    marker = JSON.parse(Pathname.new(dir_a).join('extensions', 'neu-drs-storage-pool', 'sealed.json').read)
    expect(marker['reason']).to eq('3 objects reached the limit of 3')
    expect(marker['sealed_at']).to eq('2026-01-01T00:00:00Z')
  end

  it 'is a no-op on a root already sealed, without counting it' do
    adapter.seal!('r001', reason: 'by hand')
    expect(Dir).not_to receive(:glob)

    expect(seal(max_objects: 0)).to include(sealed: true, reason: 'already sealed', objects: nil)
  end

  it 'refuses to seal the only open root, because that stops every new deposit' do
    deposit(1)
    adapter.seal!('r002')

    expect(seal(max_objects: 1)).to include(sealed: false, reason: described_class::LAST_ROOT_REFUSAL)
    expect(adapter).not_to be_sealed('r001')
    expect(adapter.open_root_name).to eq('r001')
  end

  it 'seals the only open root when an operator forces it' do
    deposit(1)
    adapter.seal!('r002')

    expect(seal(max_objects: 1, force: true)).to include(sealed: true)
    expect { adapter.open_root_name }.to raise_error(Valkyrie::Storage::OCFL::PoolSealed)
  end

  it 'counts OCFL objects only, not the root own extensions directory' do
    deposit(1)
    # bootstrap! wrote extensions/<layout>/config.json and extensions/<pool>/config.json,
    # both of which sit at the same depth a glob on directory shape would match.
    expect(Pathname.new(dir_a).join('extensions')).to exist

    expect(seal(max_objects: 99)[:objects]).to eq(1)
  end
end
