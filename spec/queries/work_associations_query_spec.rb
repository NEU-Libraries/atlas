# frozen_string_literal: true

require 'rails_helper'

RSpec.describe WorkAssociationsQuery do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:codebook)   { WorkCreator.call(parent_id: collection.noid) }
  let(:dataset)    { WorkCreator.call(parent_id: collection.noid) }

  describe '.call' do
    it 'returns empty maps for a work with no edges' do
      expect(described_class.call(codebook)).to eq(outbound: {}, inbound: {})
    end

    it 'reports the edge as outbound on the asserting work' do
      asserted = WorkAssociationCreator.call(work: codebook, target: dataset, type: 'is_codebook_for')

      expect(described_class.call(asserted)).to eq(
        outbound: { 'is_codebook_for' => [dataset.noid] }, inbound: {}
      )
    end

    # The reverse edge is never stored — this is the whole point of one edge,
    # two reads.
    it 'reports the same edge as inbound on the target' do
      WorkAssociationCreator.call(work: codebook, target: dataset, type: 'is_codebook_for')

      expect(described_class.call(Work.find(dataset.noid))).to eq(
        outbound: {}, inbound: { 'is_codebook_for' => [codebook.noid] }
      )
    end

    it 'groups several asserters under one predicate' do
      other = WorkCreator.call(parent_id: collection.noid)
      WorkAssociationCreator.call(work: codebook, target: dataset, type: 'is_figure_for')
      WorkAssociationCreator.call(work: other, target: dataset, type: 'is_figure_for')

      inbound = described_class.call(Work.find(dataset.noid))[:inbound]

      expect(inbound['is_figure_for']).to match_array([codebook.noid, other.noid])
    end

    it 'carries both directions at once' do
      WorkAssociationCreator.call(work: codebook, target: dataset, type: 'is_codebook_for')
      WorkAssociationCreator.call(work: dataset, target: codebook, type: 'is_transcription_of')

      result = described_class.call(Work.find(codebook.noid))

      expect(result[:outbound]).to eq('is_codebook_for' => [dataset.noid])
      expect(result[:inbound]).to eq('is_transcription_of' => [dataset.noid])
    end

    it 'omits predicates that hold no edges' do
      asserted = WorkAssociationCreator.call(work: codebook, target: dataset, type: 'is_codebook_for')

      expect(described_class.call(asserted)[:outbound].keys).to eq(['is_codebook_for'])
    end
  end
end
