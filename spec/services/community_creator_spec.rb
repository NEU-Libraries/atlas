# frozen_string_literal: true

require 'rails_helper'

# Mirrors spec/services/work_creator_spec.rb / collection_creator_spec.rb.
# Communities are roots — parent_id is optional and there's no
# parent.permissions copy when omitted, so provenance stamping must work
# without a parent.
RSpec.describe CommunityCreator do
  describe 'self-deposit on a root community (no parent)' do
    it 'stamps depositor == proxy_uploader == actor and emits structural + permissions-grant rows' do
      expect do
        @community = described_class.call(
          proxy_uploader: '000000002',
          actor_nuid:     '000000002'
        )
      end.to change(AuditEvent, :count).by(2)

      expect(@community.depositor).to      eq('000000002')
      expect(@community.proxy_uploader).to eq('000000002')

      ev = AuditEvent.find_by(change_type: 'structural')
      expect(ev).to have_attributes(
        actor_nuid:        '000000002',
        on_behalf_of_nuid: nil,
        action:            'create',
        change_type:       'structural',
        event_source:      'controller',
        resource_id:       @community.id.to_s,
        resource_type:     'Community'
      )
    end
  end

  describe 'in-band proxy (depositor explicit, librarian on the keyboard)' do
    it 'stamps the supplied depositor and records the librarian as proxy_uploader' do
      @community = described_class.call(
        proxy_uploader: '000000002',
        depositor:      '900000001',
        actor_nuid:     '000000002'
      )

      expect(@community.depositor).to      eq('900000001')
      expect(@community.proxy_uploader).to eq('000000002')

      ev = AuditEvent.find_by(change_type: 'structural')
      expect(ev.actor_nuid).to        eq('000000002')
      expect(ev.on_behalf_of_nuid).to eq('900000001')
    end
  end

  describe 'no provenance kwargs (internal callers like reset.rake / specs)' do
    it 'creates the Community and skips AuditEvent when actor_nuid is absent' do
      expect { @community = described_class.call }
        .not_to change(AuditEvent, :count)
      expect(@community).to be_a(Community)
    end
  end

  # Fix A: a root Community has no parent to inherit from, so its grant is
  # tagged "initial" with no parent note; a nested Community inherits.
  describe 'permissions grant at create' do
    it 'tags a root community grant as initial with no parent note' do
      @community = described_class.call(actor_nuid: '000000004')

      grant = AuditEvent.find_by(action: 'create', change_type: 'permissions')
      expect(grant).not_to be_nil
      expect(grant.payload['before']).to eq({})
      expect(grant.payload['source']).to eq('initial')
      expect(grant.note).to be_nil
    end

    it 'tags a nested community grant as inherited from its parent' do
      parent     = described_class.call                                          # root, no actor -> no events
      @community = described_class.call(parent_id: parent.noid, actor_nuid: '000000004')

      grant = AuditEvent.find_by(action: 'create', change_type: 'permissions')
      expect(grant.payload['source']).to eq('inherited')
      expect(grant.note).to              eq("inherited from #{parent.noid}")
    end
  end
end
