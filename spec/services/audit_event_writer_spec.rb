# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AuditEventWriter do
  describe '.record' do
    let(:community) { CommunityCreator.call }

    it 'persists an AuditEvent for a resource action' do
      expect do
        described_class.record(
          resource:     community,
          actor_nuid:   '000000002',
          action:       'create',
          change_type:  'structural',
          event_source: 'controller'
        )
      end.to change(AuditEvent, :count).by(1)

      ev = AuditEvent.last
      expect(ev).to have_attributes(
        resource_id:   community.id.to_s,
        resource_type: 'Community',
        actor_nuid:    '000000002',
        action:        'create',
        change_type:   'structural',
        event_source:  'controller'
      )
    end

    it 'permits nil resource for session events' do
      expect do
        described_class.record(
          actor_nuid:   '000000004',
          action:       'impersonation_started',
          change_type:  'session',
          event_source: 'controller'
        )
      end.to change(AuditEvent, :count).by(1)

      expect(AuditEvent.last.resource_id).to be_nil
    end

    it 'records on_behalf_of_nuid when supplied' do
      described_class.record(
        resource:          community,
        actor_nuid:        '000000004',
        on_behalf_of_nuid: '000000099',
        action:            'create',
        change_type:       'structural',
        event_source:      'controller'
      )
      expect(AuditEvent.last.on_behalf_of_nuid).to eq('000000099')
    end

    it 'accepts a structured payload + note' do
      described_class.record(
        resource:     community,
        actor_nuid:   '000000004',
        action:       'update',
        change_type:  'permissions',
        event_source: 'script',
        payload:      { old_role: 'standard', new_role: 'loader' },
        note:         'Manager request — ingest cohort onboarding'
      )
      ev = AuditEvent.last
      expect(ev.payload).to eq('old_role' => 'standard', 'new_role' => 'loader')
      expect(ev.note).to eq('Manager request — ingest cohort onboarding')
    end

    it 'raises on invalid input' do
      expect do
        described_class.record(
          resource:     community,
          actor_nuid:   '000000002',
          action:       'frobnicate',
          change_type:  'structural',
          event_source: 'controller'
        )
      end.to raise_error(ActiveRecord::RecordInvalid)
    end
  end
end
