# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'User#set_role audit emission' do
  let(:target) do
    User.create!(email: 'target@example.invalid', password: SecureRandom.hex(16),
                 nuid: '000000050', name: 'Target, User', role: :standard)
  end
  let(:actor_nuid) { '000000004' }

  describe '#set_role' do
    it 'updates the role and emits one AuditEvent row' do
      expect { target.set_role(:loader, actor_nuid: actor_nuid) }
        .to change(AuditEvent, :count).by(1)

      expect(target.reload.role).to eq('loader')

      ev = AuditEvent.last
      expect(ev).to have_attributes(
        actor_nuid:   actor_nuid,
        action:       'update',
        change_type:  'permissions',
        event_source: 'script'
      )
      expect(ev.payload).to include(
        'old_role'    => 'standard',
        'new_role'    => 'loader',
        'target_nuid' => target.nuid
      )
    end

    it 'refuses to mutate without an actor_nuid' do
      expect { target.set_role(:admin, actor_nuid: nil) }
        .to raise_error(ArgumentError, /actor_nuid required/)

      expect(target.reload.role).to eq('standard')
      expect(AuditEvent.where(change_type: 'permissions').count).to eq(0)
    end

    it 'records the Manager rationale in note when supplied' do
      target.set_role(:loader, actor_nuid: actor_nuid,
                               note:       'Manager request — ingest cohort onboarding')
      expect(AuditEvent.last.note).to eq('Manager request — ingest cohort onboarding')
    end
  end
end
