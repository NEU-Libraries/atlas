# frozen_string_literal: true

require 'rails_helper'

RSpec.describe LinkedMemberRemover do
  let!(:community) { Atlas.persister.save(resource: Community.new) }
  let!(:home)      { Atlas.persister.save(resource: Collection.new(a_member_of: community.id)) }
  let!(:other)     { Atlas.persister.save(resource: Collection.new(a_member_of: community.id)) }
  let!(:work)      { Atlas.persister.save(resource: Work.new(a_member_of: home.id, a_linked_member_of: [other.id])) }

  it 'removes the link' do
    described_class.call(work: work, collection: other)

    expect(Array(Work.find(work.id).a_linked_member_of)).to be_empty
  end

  it 'is idempotent — removing an absent link is a no-op, not an error' do
    plain = Atlas.persister.save(resource: Work.new(a_member_of: home.id))

    expect { described_class.call(work: plain, collection: other) }.not_to raise_error
    expect(Array(Work.find(plain.id).a_linked_member_of)).to be_empty
  end

  describe 'audit' do
    it 'records an unlink_member event when an actor is present' do
      expect { described_class.call(work: work, collection: other, actor_nuid: '000000004') }
        .to change(AuditEvent, :count).by(1)

      expect(AuditEvent.order(:created_at).last.action).to eq('unlink_member')
    end
  end
end
