# frozen_string_literal: true

require 'rails_helper'

RSpec.describe LinkedMemberCreator do
  let!(:community)   { Atlas.persister.save(resource: Community.new) }
  let!(:home)        { Atlas.persister.save(resource: Collection.new(a_member_of: community.id)) }
  let!(:other)       { Atlas.persister.save(resource: Collection.new(a_member_of: community.id)) }
  let!(:work)        { Atlas.persister.save(resource: Work.new(a_member_of: home.id)) }

  def linked_ids(work)
    Array(Work.find(work.id).a_linked_member_of).map(&:to_s)
  end

  it 'appends the collection to a_linked_member_of without touching a_member_of' do
    described_class.call(work: work, collection: other)

    reloaded = Work.find(work.id)
    expect(linked_ids(reloaded)).to contain_exactly(other.id.to_s)
    expect(reloaded.a_member_of.to_s).to eq(home.id.to_s) # structural home unchanged
  end

  it 'is idempotent — adding the same link twice yields one entry' do
    described_class.call(work: work, collection: other)
    described_class.call(work: Work.find(work.id), collection: other)

    expect(linked_ids(work)).to contain_exactly(other.id.to_s)
  end

  it 'does not change the Work ACL (linking adds placement, never permission)' do
    before_perms = work.permissions
    described_class.call(work: work, collection: other)

    expect(Work.find(work.id).permissions).to eq(before_perms)
  end

  it 'rejects a Community target' do
    expect { described_class.call(work: work, collection: community) }
      .to raise_error(Exceptions::LinkedMemberError) { |e| expect(e.code).to eq('invalid_target_type') }
  end

  it 'rejects linking into the Work\'s own structural home (redundant)' do
    expect { described_class.call(work: work, collection: home) }
      .to raise_error(Exceptions::LinkedMemberError) { |e| expect(e.code).to eq('already_structural_member') }
  end

  it 'rejects a tombstoned work' do
    work.tombstoned = true
    Atlas.persister.save(resource: work)
    expect { described_class.call(work: work, collection: other) }
      .to raise_error(Exceptions::LinkedMemberError) { |e| expect(e.code).to eq('tombstoned_work') }
  end

  it 'rejects a tombstoned target collection' do
    other.tombstoned = true
    Atlas.persister.save(resource: other)
    expect { described_class.call(work: work, collection: other) }
      .to raise_error(Exceptions::LinkedMemberError) { |e| expect(e.code).to eq('tombstoned_target') }
  end

  describe 'audit' do
    it 'records a link_member event when an actor is present' do
      expect { described_class.call(work: work, collection: other, actor_nuid: '000000004') }
        .to change(AuditEvent, :count).by(1)

      event = AuditEvent.order(:created_at).last
      expect(event.action).to eq('link_member')
      expect(event.payload['collection']).to eq(other.noid)
    end

    it 'skips the audit event for internal callers (no actor)' do
      expect { described_class.call(work: work, collection: other) }.not_to change(AuditEvent, :count)
    end
  end
end
