# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DerivativePermissionsUpdater do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }

  # A persisted Work with the given read_groups (WorkCreator inherits [] from
  # the fresh collection, so set visibility explicitly per case).
  def work_with(read_groups)
    w = WorkCreator.call(parent_id: collection.noid)
    w.read_groups = read_groups
    Atlas.persister.save(resource: w)
  end

  describe 'valid policies' do
    it 'stores a full narrowing policy on a public Work' do
      work = work_with(['public'])
      saved = described_class.call(work: work, policy: {
                                     'small' => ['public'], 'medium' => ['public'],
                                     'large' => ['grp:archives'], 'service' => ['grp:archives']
                                   })
      expect(saved.derivative_permissions_map).to eq(
        small: ['public'], medium: ['public'], large: ['grp:archives'], service: ['grp:archives']
      )
    end

    it 'accepts a partial policy — an absent higher tier inherits the set lower tier' do
      work = work_with(['public'])
      described_class.call(work: work, policy: { 'large' => ['grp:archives'] })
      # service is absent → cascades to large; large is gated, service inherits it.
      expect(work.derivative_gate_for(Role.service_file.name)).to eq(['grp:archives'])
      expect(work.derivative_gate_for(Role.small_image.name)).to eq(['public'])
    end

    it 'collapses a value containing public to [public]' do
      work = work_with(['public'])
      described_class.call(work: work, policy: { 'small' => %w[public grp:x] })
      expect(work.derivative_permissions_map[:small]).to eq(['public'])
    end

    it 'accepts an empty policy (no-op; all tiers inherit the Work)' do
      work = work_with(['grp:a'])
      expect { described_class.call(work: work, policy: {}) }.not_to raise_error
      expect(work.derivative_permissions_map).to eq({})
    end
  end

  describe 'invariant violations' do
    it 'rejects a tier more visible than the Work (tier_exceeds_resource)' do
      work = work_with(['grp:a'])
      expect { described_class.call(work: work, policy: { 'small' => ['grp:b'] }) }
        .to raise_error(Exceptions::DerivativePermissionsError) { |e| expect(e.code).to eq(:tier_exceeds_resource) }
    end

    it 'rejects a public tier on a non-public Work (tier_exceeds_resource)' do
      work = work_with(['grp:a'])
      expect { described_class.call(work: work, policy: { 'small' => ['public'] }) }
        .to raise_error(Exceptions::DerivativePermissionsError) { |e| expect(e.code).to eq(:tier_exceeds_resource) }
    end

    it 'rejects visibility that widens with resolution (tier_ordering_violation)' do
      work = work_with(['public'])
      expect { described_class.call(work: work, policy: { 'small' => ['grp:a'], 'medium' => ['public'] }) }
        .to raise_error(Exceptions::DerivativePermissionsError) { |e| expect(e.code).to eq(:tier_ordering_violation) }
    end

    it 'rejects an unknown tier key (unknown_tier) before persisting' do
      work = work_with(['public'])
      expect { described_class.call(work: work, policy: { 'huge' => ['public'] }) }
        .to raise_error(Exceptions::DerivativePermissionsError) { |e| expect(e.code).to eq(:unknown_tier) }
      expect(Work.find(work.noid).derivative_permissions_map).to eq({})
    end

    it 'forbids any visible tier on a private ([]) Work' do
      work = work_with([])
      expect { described_class.call(work: work, policy: { 'large' => ['grp:a'] }) }
        .to raise_error(Exceptions::DerivativePermissionsError)
    end
  end

  describe 'read-time clamp (policy vs. a later Work narrowing)' do
    it 'clamps a stored tier to the Work’s current visibility' do
      work = work_with(['public'])
      described_class.call(work: work, policy: { 'large' => ['grp:a'] })
      # The Work is later narrowed to a different group without re-validating
      # the policy; the effective gate can never exceed the Work.
      work.read_groups = ['grp:b']
      expect(work.derivative_gate_for(Role.large_image.name)).to eq([]) # grp:a ∩ grp:b
      expect(work.derivative_gated?(Role.large_image.name)).to be(true)
      expect(work.derivative_gate_for(Role.small_image.name)).to eq(['grp:b']) # cascades to Work
    end
  end
end
