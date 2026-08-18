# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Valkyrie::Storage::OCFL::RootConfig do
  def roots(extra)
    described_class.roots(primary_name: 'r001', primary_path: Pathname.new('/mnt/one'), extra: extra)
  end

  it 'keeps one root when no extras are named' do
    expect(roots('')).to eq('r001' => Pathname.new('/mnt/one'))
    expect(roots(nil)).to eq('r001' => Pathname.new('/mnt/one'))
  end

  it 'appends named roots after the primary, in the order given' do
    result = roots('r002=/mnt/two,r003=/mnt/three')

    expect(result.keys).to eq(%w[r001 r002 r003])
    expect(result['r003']).to eq(Pathname.new('/mnt/three'))
  end

  it 'tolerates whitespace and empty entries' do
    expect(roots(' r002 = /mnt/two , ,')).to eq('r001' => Pathname.new('/mnt/one'),
                                                'r002' => Pathname.new('/mnt/two'))
  end

  # A root missing from the pool is a root whose objects cannot be found, so a
  # typo has to stop the boot rather than quietly shrink the roster.
  it 'refuses an entry with no path' do
    expect { roots('r002') }.to raise_error(ArgumentError, /name=path/)
    expect { roots('r002=') }.to raise_error(ArgumentError, /name=path/)
  end

  it 'refuses to redefine the primary root, which would move it silently' do
    expect { roots('r001=/mnt/somewhere-else') }
      .to raise_error(ArgumentError, /cannot redefine the primary root/)
  end

  it 'reads the environment by default' do
    stub_const('ENV', ENV.to_h.merge(described_class::ENV_VAR => 'r002=/mnt/two'))

    result = described_class.roots(primary_name: 'r001', primary_path: Pathname.new('/mnt/one'))

    expect(result.keys).to eq(%w[r001 r002])
  end
end
