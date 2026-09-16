# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TestStorage do
  describe '.root' do
    it 'is tmp/files for the first worker, which parallel_tests leaves unnumbered' do
      with_env('TEST_ENV_NUMBER' => nil) do
        expect(described_class.root).to eq(Rails.root.join('tmp/files'))
      end
    end

    it 'is suffixed for the rest, so two workers cannot wipe each other\'s blobs' do
      with_env('TEST_ENV_NUMBER' => '2') do
        expect(described_class.root).to eq(Rails.root.join('tmp/files2'))
      end
    end
  end

  # Named by the :test_disk adapter at boot, so a root that drifted from this
  # would leave every spec that clears the root by name clearing the wrong one.
  it 'names the root the :test_disk adapter actually writes to' do
    adapter_root = Valkyrie::StorageAdapter.find(:test_disk).storage_roots.values.first.base_path

    expect(adapter_root).to eq(described_class.root)
  end
end
