# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TierVisibility do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }

  # Assets the gate resolves for: image-derivative Delegates (by `use`) and
  # held Blobs (by media type).
  def delegate(use)  = Delegate.new(use: use)
  def blob(mime)     = Blob.new(mime_type: mime)

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

  describe '.media_tier (Blob mime => policy tier)' do
    it 'maps an image original to master, pdf/audio/video to their own tiers' do
      expect(described_class.media_tier('image/tiff')).to eq(:master)
      expect(described_class.media_tier('application/pdf')).to eq(:pdf)
      expect(described_class.media_tier('audio/mpeg')).to eq(:audio)
      expect(described_class.media_tier('video/mp4')).to eq(:video)
    end

    it 'has no tier for other or blank media types' do
      expect(described_class.media_tier('text/plain')).to be_nil
      expect(described_class.media_tier('application/zip')).to be_nil
      expect(described_class.media_tier(nil)).to be_nil
    end
  end

  describe '#derivative_gate_for / #derivative_gated? — image ladder' do
    let(:work) do
      Work.new(read_groups:            ['public'],
               derivative_permissions: JSON.dump(large: ['grp:archives']))
    end

    it 'gates large to its group and cascades service AND master down to it' do
      expect(work.derivative_gate_for(delegate(Role.large_image.name))).to eq(['grp:archives'])
      expect(work.derivative_gated?(delegate(Role.large_image.name))).to be(true)
      expect(work.derivative_gate_for(delegate(Role.service_file.name))).to eq(['grp:archives'])
      # The image original Blob is the `master` floor — gating `large` closes it too.
      expect(work.derivative_gate_for(blob('image/tiff'))).to eq(['grp:archives'])
      expect(work.derivative_gated?(blob('image/tiff'))).to be(true)
    end

    it 'leaves lower tiers public (inherited from the Work)' do
      expect(work.derivative_gate_for(delegate(Role.small_image.name))).to eq(['public'])
      expect(work.derivative_gated?(delegate(Role.small_image.name))).to be(false)
    end

    it 'lets master be reserved without moving the sized copies above it' do
      w = Work.new(read_groups:            ['public'],
                   derivative_permissions: JSON.dump(master: ['grp:archives']))
      expect(w.derivative_gated?(blob('image/tiff'))).to be(true)
      expect(w.derivative_gate_for(blob('image/tiff'))).to eq(['grp:archives'])
      # only the floor moved — the sized copies stay public
      expect(w.derivative_gated?(delegate(Role.large_image.name))).to be(false)
    end

    it 'resolves a non-tier asset (thumbnail chrome, text sidecar) to the Work read_groups' do
      expect(work.derivative_gate_for(delegate(Role.thumbnail_image.name))).to eq(['public'])
      expect(work.derivative_gated?(delegate(Role.thumbnail_image.name))).to be(false)
      expect(work.derivative_gated?(blob('text/plain'))).to be(false)
    end
  end

  describe '#derivative_gate_for — independent media (audio/video/pdf)' do
    it 'gates only its own media, uncoupled from the image ladder' do
      work = Work.new(read_groups:            ['public'],
                      derivative_permissions: JSON.dump(large: ['grp:archives'], pdf: ['grp:pdf']))
      expect(work.derivative_gate_for(blob('application/pdf'))).to eq(['grp:pdf'])
      expect(work.derivative_gated?(blob('application/pdf'))).to be(true)
      # image ladder gating does not spill onto audio/video
      expect(work.derivative_gated?(blob('audio/mpeg'))).to be(false)
      expect(work.derivative_gated?(blob('video/mp4'))).to be(false)
    end

    it 'does not cascade: an absent media key rides the Work, not a sibling media key' do
      work = Work.new(read_groups:            ['public'],
                      derivative_permissions: JSON.dump(audio: ['grp:a']))
      expect(work.derivative_gate_for(blob('video/mp4'))).to eq(['public'])
      expect(work.derivative_gated?(blob('video/mp4'))).to be(false)
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
