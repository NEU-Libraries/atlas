# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Reparenter do
  # community ─┬─ collection_a ── nested (── deep_work)
  #            └─ collection_b
  let!(:community)    { Atlas.persister.save(resource: Community.new) }
  let!(:collection_a) { Atlas.persister.save(resource: Collection.new(a_member_of: community.id)) }
  let!(:collection_b) { Atlas.persister.save(resource: Collection.new(a_member_of: community.id)) }
  let!(:nested)       { Atlas.persister.save(resource: Collection.new(a_member_of: collection_a.id)) }
  let!(:deep_work)    { Atlas.persister.save(resource: Work.new(a_member_of: nested.id)) }

  def ancestor_ids(resource)
    doc = Atlas.index_adapter.connection.get(
      'select', params: { q: %(id:"#{resource.id}"), fl: 'ancestor_ids_ssim' }
    ).dig('response', 'docs').first
    doc['ancestor_ids_ssim']
  end

  describe 'a valid move' do
    it 'reassigns a_member_of as a scalar to the new parent' do
      described_class.call(node: collection_a, destination: collection_b)

      moved = Collection.find(collection_a.id)
      expect(moved.a_member_of).to be_a(Valkyrie::ID)
      expect(moved.a_member_of.to_s).to eq(collection_b.id.to_s)
    end

    it 'recomputes ancestor_ids_ssim for the moved node and its descendant collections' do
      described_class.call(node: collection_a, destination: collection_b)

      # collection_a now sits under collection_b under community
      expect(ancestor_ids(collection_a)).to contain_exactly(collection_b.noid, community.noid)
      # nested rode along: its chain now includes the new path
      expect(ancestor_ids(nested)).to contain_exactly(collection_a.noid, collection_b.noid, community.noid)
    end

    it 'cascades only to collections/communities — never to Works' do
      captured = nil
      allow(SubtreeReindexer).to receive(:call) do |resources:|
        captured = resources
      end

      described_class.call(node: collection_a, destination: collection_b)

      expect(captured.map(&:noid)).to contain_exactly(nested.noid)
      expect(captured).to all(satisfy { |r| r.is_a?(Collection) || r.is_a?(Community) })
      expect(captured.map(&:id)).not_to include(deep_work.id)
    end
  end

  describe 'validation (all before any write)' do
    it 'rejects moving a node into itself' do
      expect { described_class.call(node: collection_a, destination: collection_a) }
        .to raise_error(Exceptions::ReparentError) { |e| expect(e.code).to eq('cycle') }
    end

    it 'rejects moving a node into one of its own descendants' do
      expect { described_class.call(node: collection_a, destination: nested) }
        .to raise_error(Exceptions::ReparentError) { |e| expect(e.code).to eq('cycle') }
    end

    it 'rejects an invalid parent type (Community under a Collection)' do
      expect { described_class.call(node: community, destination: collection_a) }
        .to raise_error(Exceptions::ReparentError) { |e| expect(e.code).to eq('invalid_parent_type') }
    end

    it 'rejects a Work with no parent (only Communities may be parentless)' do
      work = Atlas.persister.save(resource: Work.new(a_member_of: collection_a.id))
      expect { described_class.call(node: work, destination: nil) }
        .to raise_error(Exceptions::ReparentError) { |e| expect(e.code).to eq('parent_required') }
    end

    it 'allows a Community to move to the top of the tree (nil parent)' do
      sub = Atlas.persister.save(resource: Community.new(a_member_of: community.id))
      expect { described_class.call(node: sub, destination: nil) }.not_to raise_error
      expect(Community.find(sub.id).a_member_of).to be_nil
    end

    it 'rejects a tombstoned node' do
      collection_a.tombstoned = true
      Atlas.persister.save(resource: collection_a)
      expect { described_class.call(node: collection_a, destination: collection_b) }
        .to raise_error(Exceptions::ReparentError) { |e| expect(e.code).to eq('tombstoned_node') }
    end

    it 'rejects a tombstoned destination' do
      collection_b.tombstoned = true
      Atlas.persister.save(resource: collection_b)
      expect { described_class.call(node: collection_a, destination: collection_b) }
        .to raise_error(Exceptions::ReparentError) { |e| expect(e.code).to eq('tombstoned_parent') }
    end
  end

  describe 'audit' do
    it 'records a structural reparent event with from/to when an actor is present' do
      expect do
        described_class.call(node: collection_a, destination: collection_b, actor_nuid: '000000004')
      end.to change(AuditEvent, :count).by(1)

      event = AuditEvent.order(:created_at).last
      expect(event.action).to eq('reparent')
      expect(event.change_type).to eq('structural')
      expect(event.payload['from']).to eq(community.noid)
      expect(event.payload['to']).to eq(collection_b.noid)
    end

    it 'skips the audit event for internal callers (no actor_nuid)' do
      expect { described_class.call(node: collection_a, destination: collection_b) }
        .not_to change(AuditEvent, :count)
    end
  end
end
