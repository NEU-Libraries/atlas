# frozen_string_literal: true

require 'rails_helper'

RSpec.describe WorkAssociationRemover do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:codebook)   { WorkCreator.call(parent_id: collection.noid) }
  let(:dataset)    { WorkCreator.call(parent_id: collection.noid) }

  describe '.call' do
    it 'removes the edge' do
      asserted = WorkAssociationCreator.call(work: codebook, target: dataset, type: 'is_codebook_for')

      result = described_class.call(work: asserted, target: dataset, type: 'is_codebook_for')

      expect(result.is_codebook_for.to_a).to be_empty
      expect(Work.find(codebook.noid).is_codebook_for.to_a).to be_empty
    end

    # The type is part of the edge's identity, not a filter on it.
    it 'leaves the other edge between the same pair standing' do
      WorkAssociationCreator.call(work: codebook, target: dataset, type: 'is_codebook_for')
      both = WorkAssociationCreator.call(work: Work.find(codebook.noid), target: dataset, type: 'is_figure_for')

      result = described_class.call(work: both, target: dataset, type: 'is_figure_for')

      expect(result.is_figure_for.to_a).to be_empty
      expect(result.is_codebook_for.map(&:to_s)).to eq([dataset.id.to_s])
    end

    it 'is a no-op for an edge that was never asserted' do
      expect do
        described_class.call(work: codebook, target: dataset, type: 'is_codebook_for')
      end.not_to raise_error
    end

    it 'is a no-op for an unknown relationship type' do
      expect do
        described_class.call(work: codebook, target: dataset, type: 'is_sequel_to')
      end.not_to raise_error
    end
  end

  describe 'the audit row' do
    it 'records the target and the type' do
      asserted = WorkAssociationCreator.call(work: codebook, target: dataset, type: 'is_codebook_for')

      expect do
        described_class.call(work: asserted, target: dataset, type: 'is_codebook_for', actor_nuid: '000000004')
      end.to change(AuditEvent, :count).by(1)

      event = AuditEvent.last
      expect(event.action).to eq('disassociate')
      expect(event.change_type).to eq('metadata')
      expect(event.payload).to include('target' => dataset.noid, 'type' => 'is_codebook_for')
    end

    it 'writes nothing when no actor is supplied' do
      asserted = WorkAssociationCreator.call(work: codebook, target: dataset, type: 'is_codebook_for')

      expect do
        described_class.call(work: asserted, target: dataset, type: 'is_codebook_for')
      end.not_to change(AuditEvent, :count)
    end
  end
end
