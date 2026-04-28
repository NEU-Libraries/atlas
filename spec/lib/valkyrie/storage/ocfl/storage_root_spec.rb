# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Valkyrie::Storage::OCFL::StorageRoot do
  let(:tmpdir) { Dir.mktmpdir('ocfl-root-spec-') }
  after { FileUtils.rm_rf(tmpdir) }

  subject(:root) { described_class.new(base_path: tmpdir) }

  describe '#bootstrap!' do
    it 'writes NAMASTE, ocfl_layout.json, and the 0007 extension config' do
      root.bootstrap!
      expect(File.read(File.join(tmpdir, '0=ocfl_1.1'))).to eq("ocfl_1.1\n")
      expect(File).to exist(File.join(tmpdir, 'ocfl_layout.json'))
      expect(File).to exist(File.join(tmpdir, 'extensions',
                                      '0007-n-tuple-omit-prefix-storage-layout', 'config.json'))
    end

    it 'is idempotent — running twice does not raise or rewrite' do
      root.bootstrap!
      mtime = File.mtime(File.join(tmpdir, '0=ocfl_1.1'))
      sleep 0.01
      root.bootstrap!
      expect(File.mtime(File.join(tmpdir, '0=ocfl_1.1'))).to eq(mtime)
    end
  end

  describe '#object_root_for' do
    it 'maps a 9-char NOID to <root>/aa/bb/<full-noid>/ with default tuple (2,2)' do
      expect(root.object_root_for('abcd1234e').to_s).to eq(File.join(tmpdir, 'ab', 'cd', 'abcd1234e'))
    end

    it 'maps a uuid' do
      key = 'abcdef12-3456-7890-aaaa-bbbbccccdddd'
      expect(root.object_root_for(key).to_s).to eq(File.join(tmpdir, 'ab', 'cd', key))
    end

    it 'right-pads when the key is shorter than the tuple bytes' do
      expect(root.object_root_for('abc').to_s).to eq(File.join(tmpdir, 'ab', 'c0', 'abc'))
    end
  end
end
