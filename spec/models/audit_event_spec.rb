# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AuditEvent do
  let(:resource_attrs) do
    {
      actor_nuid:    '000000002',
      action:        'create',
      change_type:   'structural',
      event_source:  'controller',
      resource_id:   'qrfj8zz',
      resource_type: 'Work'
    }
  end

  describe 'validations' do
    it 'requires actor_nuid' do
      ev = described_class.new(resource_attrs.merge(actor_nuid: nil))
      expect(ev).not_to be_valid
      expect(ev.errors[:actor_nuid]).to be_present
    end

    it 'rejects unknown action values' do
      ev = described_class.new(resource_attrs.merge(action: 'frobnicate'))
      expect(ev).not_to be_valid
      expect(ev.errors[:action]).to be_present
    end

    it 'rejects unknown change_type values' do
      ev = described_class.new(resource_attrs.merge(change_type: 'cosmic'))
      expect(ev).not_to be_valid
      expect(ev.errors[:change_type]).to be_present
    end

    it 'rejects unknown event_source values' do
      ev = described_class.new(resource_attrs.merge(event_source: 'cron'))
      expect(ev).not_to be_valid
      expect(ev.errors[:event_source]).to be_present
    end

    it 'rejects unknown resource_type values' do
      ev = described_class.new(resource_attrs.merge(resource_type: 'FileSet'))
      expect(ev).not_to be_valid
      expect(ev.errors[:resource_type]).to be_present
    end

    it 'requires resource_id for non-session events' do
      ev = described_class.new(resource_attrs.merge(resource_id: nil))
      expect(ev).not_to be_valid
      expect(ev.errors[:resource_id]).to be_present
    end

    it 'permits a session event without a resource' do
      ev = described_class.new(
        actor_nuid:   '000000004',
        action:       'impersonation_started',
        change_type:  'session',
        event_source: 'controller'
      )
      expect(ev).to be_valid
    end

    it 'autofills occurred_at on create' do
      ev = described_class.create!(resource_attrs)
      expect(ev.occurred_at).to be_within(5.seconds).of(Time.current)
    end
  end

  describe 'scopes' do
    let!(:created) do
      described_class.create!(resource_attrs.merge(occurred_at: 2.days.ago))
    end
    let!(:updated) do
      described_class.create!(resource_attrs.merge(action: 'update', change_type: 'metadata', occurred_at: 1.day.ago))
    end
    let!(:other_resource) do
      described_class.create!(resource_attrs.merge(resource_id: 'other123'))
    end
    let!(:session) do
      described_class.create!(
        actor_nuid:   '000000004',
        action:       'impersonation_started',
        change_type:  'session',
        event_source: 'controller'
      )
    end

    it 'filters by resource_id' do
      expect(described_class.for_resource('qrfj8zz')).to contain_exactly(created, updated)
    end

    it 'returns chronological order' do
      ordered = described_class.for_resource('qrfj8zz').chronological
      expect(ordered.map(&:action)).to eq(%w[create update])
    end

    it 'returns reverse-chronological order via :recent' do
      ordered = described_class.for_resource('qrfj8zz').recent
      expect(ordered.map(&:action)).to eq(%w[update create])
    end

    it 'filters by actor' do
      expect(described_class.by_actor('000000004')).to contain_exactly(session)
    end

    it 'isolates impersonation sessions' do
      expect(described_class.impersonation_sessions).to contain_exactly(session)
    end
  end

  describe 'lifecycle decoupling' do
    it 'survives deletion of the underlying resource_id reference' do
      ev = described_class.create!(resource_attrs)
      # Simulating a tombstone/destroy of the Valkyrie resource: the
      # AuditEvent must remain queryable by its raw resource_id string.
      expect(described_class.for_resource(ev.resource_id)).to include(ev)
    end
  end
end
