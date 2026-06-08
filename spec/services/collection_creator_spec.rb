# frozen_string_literal: true

require 'rails_helper'

# Mirrors spec/services/work_creator_spec.rb. Containers (Collection,
# Community) carry the same proxy_uploader/depositor provenance pair as
# Works — the gap report on collection/community provenance covers the
# motivation.
RSpec.describe CollectionCreator do
  let(:community) { CommunityCreator.call }

  describe 'self-deposit' do
    it 'stamps depositor == proxy_uploader == actor and emits structural + permissions-grant rows' do
      expect do
        @collection = described_class.call(
          parent_id:      community.noid,
          proxy_uploader: '000000002',
          actor_nuid:     '000000002'
        )
      end.to change(AuditEvent, :count).by(2)

      expect(@collection.depositor).to      eq('000000002')
      expect(@collection.proxy_uploader).to eq('000000002')

      ev = AuditEvent.find_by(change_type: 'structural')
      expect(ev).to have_attributes(
        actor_nuid:        '000000002',
        on_behalf_of_nuid: nil, # actor == depositor → no proxy attribution
        action:            'create',
        change_type:       'structural',
        event_source:      'controller',
        resource_id:       @collection.id.to_s,
        resource_type:     'Collection'
      )
    end
  end

  describe 'in-band proxy (depositor explicit, librarian on the keyboard)' do
    it 'stamps the supplied depositor and records the librarian as proxy_uploader' do
      @collection = described_class.call(
        parent_id:      community.noid,
        proxy_uploader: '000000002',           # librarian
        depositor:      '900000001',           # faculty
        actor_nuid:     '000000002'
      )

      expect(@collection.depositor).to      eq('900000001')
      expect(@collection.proxy_uploader).to eq('000000002')

      ev = AuditEvent.find_by(change_type: 'structural')
      expect(ev.actor_nuid).to        eq('000000002')
      expect(ev.on_behalf_of_nuid).to eq('900000001') # depositor differs → implicit on_behalf_of
    end
  end

  describe 'no provenance kwargs (internal callers like reset.rake / specs)' do
    it 'creates the Collection and skips AuditEvent when actor_nuid is absent' do
      expect { @collection = described_class.call(parent_id: community.noid) }
        .not_to change(AuditEvent, :count)
      expect(@collection).to be_a(Collection)
    end
  end

  describe 'permissions-copy ordering regression' do
    let(:community_with_depositor) do
      c = CommunityCreator.call
      c.depositor = 'inherited_from_community'
      Atlas.persister.save(resource: c)
    end

    it 'preserves the CollectionCreator-supplied proxy_uploader across the parent.permissions copy' do
      @collection = described_class.call(
        parent_id:      community_with_depositor.noid,
        proxy_uploader: 'librarian_stamping_here',
        actor_nuid:     'librarian_stamping_here'
      )

      # If the ordering ever inverts, the librarian's stamp would be
      # clobbered by the inherited nil/parent value.
      expect(@collection.proxy_uploader).to eq('librarian_stamping_here')
    end
  end

  # Fix A: a Collection's starting ACL is inherited from its parent Community.
  describe 'permissions grant at create' do
    it 'emits an inherited permissions grant naming the parent community' do
      @collection = described_class.call(parent_id: community.noid, actor_nuid: '000000004')

      grant = AuditEvent.find_by(action: 'create', change_type: 'permissions')
      expect(grant).not_to be_nil
      expect(grant.resource_id).to                  eq(@collection.id.to_s)
      expect(grant.payload['before']).to            eq({})
      expect(grant.payload.dig('after', 'edit')).to include(Permissions::STAFF_EDIT_GROUP)
      expect(grant.payload['source']).to            eq('inherited')
      expect(grant.note).to                         eq("inherited from #{community.noid}")
    end
  end
end
