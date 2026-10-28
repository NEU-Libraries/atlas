# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Valkyrie::Storage::OCFL, 'object logs' do
  let(:adapter) { Valkyrie.config.storage_adapter }
  let(:work)    { WorkCreator.call(parent_id: CollectionCreator.call(parent_id: CommunityCreator.call.noid).noid) }
  let(:root)    { adapter.storage_roots.values.first.object_root_for(work.noid) }

  after { Atlas.persister.wipe! }

  def inventory_head
    JSON.parse(root.join('inventory.json').read)['head']
  end

  it 'appends to logs/ without cutting a version' do
    head = inventory_head
    expect(adapter.append_log(key: work.noid, name: 'fixity.jsonl', line: '{"n":1}')).to eq(:appended)
    expect(adapter.append_log(key: work.noid, name: 'fixity.jsonl', line: '{"n":2}')).to eq(:appended)

    expect(root.join('logs/fixity.jsonl').read).to eq(%({"n":1}\n{"n":2}\n))
    expect(inventory_head).to eq(head)
    expect(adapter.read_log(key: work.noid, name: 'fixity.jsonl')).to eq(['{"n":1}', '{"n":2}'])
  end

  # A retried request must not record the same check twice.
  it 'skips a line identical to the last one' do
    adapter.append_log(key: work.noid, name: 'fixity.jsonl', line: '{"n":1}')
    expect(adapter.append_log(key: work.noid, name: 'fixity.jsonl', line: '{"n":1}')).to eq(:duplicate)
    expect(adapter.read_log(key: work.noid, name: 'fixity.jsonl')).to eq(['{"n":1}'])
  end

  it 'keeps the footprint ledger equal to the bytes on disk' do
    adapter.append_log(key: work.noid, name: 'fixity.jsonl', line: '{"n":1}')
    expect(StorageFootprint.find(work.noid).bytes).to eq(adapter.measure_object(key: work.noid))
  end

  it 'leaves the object valid OCFL' do
    adapter.append_log(key: work.noid, name: 'fixity.jsonl', line: '{"n":1}')
    validator = OcflHealth::ObjectValidator.new(root, key: work.noid, fixity: true).call
    expect(validator.findings.reject { |f| f.severity == :advisory }).to be_empty
  end

  it 'answers nil and writes nothing for an object no root holds' do
    expect(adapter.append_log(key: 'nosuchkey', name: 'fixity.jsonl', line: '{}')).to be_nil
    expect(adapter.read_log(key: 'nosuchkey', name: 'fixity.jsonl')).to eq([])
    expect(adapter.object_versions(key: 'nosuchkey')).to be_nil
  end

  it 'refuses a log name that could leave logs/' do
    expect { adapter.append_log(key: work.noid, name: '../inventory.json', line: '{}') }
      .to raise_error(ArgumentError)
  end

  it 'answers whether any root holds an object' do
    expect(adapter.object_exists?(key: work.noid)).to be(true)
    expect(adapter.object_exists?(key: 'nosuchkey')).to be(false)
  end

  it 'lists the versions the head inventory names' do
    expect(adapter.object_versions(key: work.noid)).to include('v1')
  end
end
