# frozen_string_literal: true

require 'rails_helper'

RSpec.describe WorkAssociationCreator do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:codebook)   { WorkCreator.call(parent_id: collection.noid) }
  let(:dataset)    { WorkCreator.call(parent_id: collection.noid) }

  describe '.call' do
    it 'stores the edge on the asserting work under the named predicate' do
      result = described_class.call(work: codebook, target: dataset, type: 'is_codebook_for')

      expect(result.is_codebook_for.map(&:to_s)).to eq([dataset.id.to_s])
      expect(Work.find(codebook.noid).is_codebook_for.map(&:to_s)).to eq([dataset.id.to_s])
    end

    it 'stores nothing on the target' do
      described_class.call(work: codebook, target: dataset, type: 'is_codebook_for')

      reloaded = Work.find(dataset.noid)
      Work::ASSOCIATION_TYPES.each { |predicate| expect(Array(reloaded[predicate])).to be_empty }
    end

    it 'is a no-op when the edge already exists' do
      described_class.call(work: codebook, target: dataset, type: 'is_codebook_for')
      result = described_class.call(work: Work.find(codebook.noid), target: dataset, type: 'is_codebook_for')

      expect(result.is_codebook_for.length).to eq(1)
    end

    it 'keeps two different edges between the same pair' do
      described_class.call(work: codebook, target: dataset, type: 'is_codebook_for')
      result = described_class.call(work: Work.find(codebook.noid), target: dataset, type: 'is_figure_for')

      expect(result.is_codebook_for.map(&:to_s)).to eq([dataset.id.to_s])
      expect(result.is_figure_for.map(&:to_s)).to eq([dataset.id.to_s])
    end

    it 'changes no permission on either end' do
      before_acl = codebook.audited_acl
      described_class.call(work: codebook, target: dataset, type: 'is_codebook_for')

      expect(Work.find(codebook.noid).audited_acl).to eq(before_acl)
      expect(Work.find(dataset.noid).audited_acl).to eq(dataset.audited_acl)
    end

    # A is a transcription of B and B is a figure for A are both meaningful,
    # and nothing walks these edges recursively.
    it 'permits a cycle' do
      described_class.call(work: codebook, target: dataset, type: 'is_transcription_of')

      expect do
        described_class.call(work: Work.find(dataset.noid), target: codebook, type: 'is_figure_for')
      end.not_to raise_error
    end
  end

  describe 'validation' do
    it 'rejects an unknown relationship type' do
      expect do
        described_class.call(work: codebook, target: dataset, type: 'is_sequel_to')
      end.to raise_error(Exceptions::WorkAssociationError) { |e| expect(e.code).to eq('invalid_type') }
    end

    it 'rejects a non-Work target' do
      expect do
        described_class.call(work: codebook, target: collection, type: 'is_codebook_for')
      end.to raise_error(Exceptions::WorkAssociationError) { |e| expect(e.code).to eq('invalid_target_type') }
    end

    it 'rejects a work associated with itself' do
      expect do
        described_class.call(work: codebook, target: codebook, type: 'is_codebook_for')
      end.to raise_error(Exceptions::WorkAssociationError) { |e| expect(e.code).to eq('self_association') }
    end

    it 'rejects a tombstoned asserter' do
      codebook.tombstone(by: '000000004')
      Atlas.persister.save(resource: codebook)

      expect do
        described_class.call(work: Work.find(codebook.noid), target: dataset, type: 'is_codebook_for')
      end.to raise_error(Exceptions::WorkAssociationError) { |e| expect(e.code).to eq('tombstoned_work') }
    end

    it 'rejects a tombstoned target' do
      dataset.tombstone(by: '000000004')
      Atlas.persister.save(resource: dataset)

      expect do
        described_class.call(work: codebook, target: Work.find(dataset.noid), type: 'is_codebook_for')
      end.to raise_error(Exceptions::WorkAssociationError) { |e| expect(e.code).to eq('tombstoned_target') }
    end

    it 'writes nothing when validation fails' do
      expect do
        described_class.call(work: codebook, target: dataset, type: 'is_sequel_to')
      end.to raise_error(Exceptions::WorkAssociationError)

      Work::ASSOCIATION_TYPES.each { |p| expect(Array(Work.find(codebook.noid)[p])).to be_empty }
    end
  end

  describe 'the audit row' do
    it 'records the target and the type as a metadata change' do
      expect do
        described_class.call(work: codebook, target: dataset, type: 'is_codebook_for', actor_nuid: '000000004')
      end.to change(AuditEvent, :count).by(1)

      event = AuditEvent.last
      expect(event.action).to eq('associate')
      expect(event.change_type).to eq('metadata')
      expect(event.payload).to include('target' => dataset.noid, 'type' => 'is_codebook_for')
    end

    it 'carries the acting-as target' do
      described_class.call(work: codebook, target: dataset, type: 'is_codebook_for',
                           actor_nuid: '000000004', on_behalf_of_nuid: '000000005')

      expect(AuditEvent.last.on_behalf_of_nuid).to eq('000000005')
    end

    it 'writes nothing when no actor is supplied' do
      expect do
        described_class.call(work: codebook, target: dataset, type: 'is_codebook_for')
      end.not_to change(AuditEvent, :count)
    end
  end
end
