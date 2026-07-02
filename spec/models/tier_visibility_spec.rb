# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TierVisibility do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }

  describe 'derivative_permissions round-trip through the metadata adapter' do
    it 'preserves array values and an explicit [] across persist/reload' do
      work = WorkCreator.call(parent_id: collection.noid)
      work.derivative_permissions = JSON.dump(small: ['public'], large: ['grp:a', 'grp:b'], service: [])
      reloaded = Work.find(Atlas.persister.save(resource: work).noid)

      map = reloaded.derivative_permissions_map
      expect(map[:small]).to eq(['public'])       # single-element array not collapsed
      expect(map[:large]).to eq(['grp:a', 'grp:b'])
      expect(map[:service]).to eq([])             # explicit private survives
      expect(map).not_to have_key(:medium)        # absent stays absent
    end

    it 'is empty for an unset or malformed policy' do
      expect(Work.new.derivative_permissions_map).to eq({})
      expect(Work.new(derivative_permissions: 'not json').derivative_permissions_map).to eq({})
    end
  end

  describe '#derivative_gate_for / #derivative_gated?' do
    let(:work) do
      Work.new(read_groups:            ['public'],
               derivative_permissions: JSON.dump(large: ['grp:archives']))
    end

    it 'gates the large tier to its group and cascades service down to it' do
      expect(work.derivative_gate_for(Role.large_image.name)).to eq(['grp:archives'])
      expect(work.derivative_gated?(Role.large_image.name)).to be(true)
      expect(work.derivative_gate_for(Role.service_file.name)).to eq(['grp:archives'])
    end

    it 'leaves lower tiers public (inherited from the Work)' do
      expect(work.derivative_gate_for(Role.small_image.name)).to eq(['public'])
      expect(work.derivative_gated?(Role.small_image.name)).to be(false)
    end

    it 'resolves a non-tier use (thumbnail chrome, originals) to the Work read_groups' do
      expect(work.derivative_gate_for(Role.thumbnail_image.name)).to eq(['public'])
      expect(work.derivative_gated?(Role.thumbnail_image.name)).to be(false)
    end
  end

  describe '.audience_subset? / .audience_intersect' do
    it 'treats public as the universal audience' do
      expect(described_class.audience_subset?(['grp:a'], ['public'])).to be(true)
      expect(described_class.audience_subset?(['public'], ['grp:a'])).to be(false)
    end

    it 'is a conservative group-set subset otherwise' do
      expect(described_class.audience_subset?(['grp:a'], ['grp:a', 'grp:b'])).to be(true)
      expect(described_class.audience_subset?(['grp:a'], ['grp:b'])).to be(false)
      expect(described_class.audience_subset?([], ['grp:a'])).to be(true) # private ⊆ anything
    end

    it 'clamps an audience to what is also visible under the outer set' do
      expect(described_class.audience_intersect(['grp:a'], ['public'])).to eq(['grp:a'])
      expect(described_class.audience_intersect(['public'], ['grp:a'])).to eq(['grp:a'])
      expect(described_class.audience_intersect(['grp:a', 'grp:b'], ['grp:b'])).to eq(['grp:b'])
    end
  end
end
