# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Valkyrie::Storage::OCFL::Inventory do
  let(:user) { { 'name' => 'Atlas', 'address' => 'mailto:lib@example.org' } }

  # One entry for the common single-file case.
  def one(digest, version, logical_path = 'foo.jpg')
    { digest: digest, logical_path: logical_path, content_path: "#{version}/content/#{logical_path}" }
  end

  describe '.empty' do
    it 'starts at v0 with empty manifest and versions' do
      inv = described_class.empty(id: 'abc')
      expect(inv.head).to eq('v0')
      expect(inv.head_int).to eq(0)
      expect(inv.empty?).to be true
      expect(inv.manifest).to eq({})
      expect(inv.versions).to eq({})
    end
  end

  describe '#bump' do
    let(:empty) { described_class.empty(id: 'abc') }

    it 'creates v1 with manifest mapping digest to content path' do
      v1 = empty.bump(entries: [one('d1', 'v1')],
                      created: '2026-01-01T00:00:00Z', message: 'm', user: user)
      expect(v1.head).to eq('v1')
      expect(v1.head_int).to eq(1)
      expect(v1.manifest).to eq('d1' => ['v1/content/foo.jpg'])
      expect(v1.versions['v1']['state']).to eq('d1' => ['foo.jpg'])
      expect(v1.versions['v1']['user']).to eq(user)
    end

    it 'dedups manifest when the digest already exists' do
      v1 = empty.bump(entries: [one('d1', 'v1')], created: 't', message: 'm', user: user)
      v2 = v1.bump(entries: [one('d1', 'v2')], created: 't', message: 'm', user: user)
      expect(v2.manifest).to eq('d1' => ['v1/content/foo.jpg'])
      expect(v2.versions.keys).to eq(%w[v1 v2])
    end

    it 'replaces the prior digest binding for the same logical path' do
      v1 = empty.bump(entries: [one('d1', 'v1')], created: 't', message: 'm', user: user)
      v2 = v1.bump(entries: [one('d2', 'v2')], created: 't', message: 'm', user: user)
      expect(v2.versions['v2']['state']).to eq('d2' => ['foo.jpg'])
      expect(v2.manifest).to eq('d1' => ['v1/content/foo.jpg'],
                                'd2' => ['v2/content/foo.jpg'])
    end
  end

  describe '#bump with several entries' do
    let(:empty) { described_class.empty(id: 'abc') }

    it 'commits every entry into one version' do
      v1 = empty.bump(entries: [one('d1', 'v1', 'relationships.json'),
                                one('d2', 'v1', 'permissions.json')],
                      created: 't', message: 'm', user: user)

      expect(v1.versions.keys).to eq(['v1'])
      expect(v1.versions['v1']['state']).to eq('d1' => ['relationships.json'],
                                               'd2' => ['permissions.json'])
      expect(v1.manifest).to eq('d1' => ['v1/content/relationships.json'],
                                'd2' => ['v1/content/permissions.json'])
    end

    it 'points two names at one content file when the bytes are identical' do
      v1 = empty.bump(entries: [one('same', 'v1', 'a.json'), one('same', 'v1', 'b.json')],
                      created: 't', message: 'm', user: user)

      expect(v1.manifest).to eq('same' => ['v1/content/a.json'])
      expect(v1.versions['v1']['state']).to eq('same' => %w[a.json b.json])
    end

    it 'carries unchanged paths forward while replacing only what the batch names' do
      v1 = empty.bump(entries: [one('d1', 'v1', 'relationships.json'),
                                one('d2', 'v1', 'permissions.json')],
                      created: 't', message: 'm', user: user)
      v2 = v1.bump(entries: [one('d3', 'v2', 'permissions.json')],
                   created: 't', message: 'm', user: user)

      expect(v2.versions['v2']['state']).to eq('d1' => ['relationships.json'],
                                               'd3' => ['permissions.json'])
    end
  end

  describe 'lookups' do
    let(:inv) do
      described_class.empty(id: 'abc')
                     .bump(entries: [one('d1', 'v1')], created: 't', message: 'm', user: user)
                     .bump(entries: [one('d2', 'v2')], created: 't', message: 'm', user: user)
    end

    it 'resolves digest_for(version, logical_path)' do
      expect(inv.digest_for(version: 'v1', logical_path: 'foo.jpg')).to eq('d1')
      expect(inv.digest_for(version: 'v2', logical_path: 'foo.jpg')).to eq('d2')
      expect(inv.digest_for(version: 'v1', logical_path: 'missing')).to be_nil
    end

    it 'resolves content_path_for(digest)' do
      expect(inv.content_path_for('d1')).to eq('v1/content/foo.jpg')
      expect(inv.content_path_for('d2')).to eq('v2/content/foo.jpg')
    end

    it 'lists versions_containing newest first by numeric vN' do
      v3 = inv.bump(entries: [one('d3', 'v3')], created: 't', message: 'm', user: user)
      v10 = (4..10).inject(v3) do |acc, n|
        acc.bump(entries: [one("d#{n}", "v#{n}")], created: 't', message: 'm', user: user)
      end
      expect(v10.versions_containing('foo.jpg')).to eq(%w[v10 v9 v8 v7 v6 v5 v4 v3 v2 v1])
    end
  end

  describe 'serialization' do
    it 'round-trips through JSON' do
      original = described_class.empty(id: 'abc')
                                .bump(entries: [one('d1', 'v1')], created: 't', message: 'm', user: user)
      reparsed = described_class.parse(original.to_json)
      expect(reparsed.id).to eq('abc')
      expect(reparsed.head).to eq('v1')
      expect(reparsed.manifest).to eq(original.manifest)
      expect(reparsed.versions).to eq(original.versions)
    end

    it 'includes the OCFL 1.1 type and digestAlgorithm' do
      h = described_class.empty(id: 'abc').to_h
      expect(h['type']).to eq('https://ocfl.io/1.1/spec/#inventory')
      expect(h['digestAlgorithm']).to eq('sha512')
      expect(h['contentDirectory']).to eq('content')
    end
  end
end
