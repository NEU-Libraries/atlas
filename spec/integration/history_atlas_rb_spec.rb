# frozen_string_literal: true

require 'rails_helper'

# atlas_rb 1.1.0 — AtlasRb::Resource.history wraps GET /resources/:id/history
# (Atlas's AuditEventsController). Cerberus consumes this for the resource
# "History" tab. Exercised here end-to-end through the live server.
RSpec.describe 'Resource history via atlas_rb', :atlas_rb_server do
  # Admin (wildcard) — AuditEvent reads are admin-only (Ability), and the
  # HTTP create path needs an authenticated actor to emit the audit row.
  let(:admin_nuid) { '000000004' }

  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }

  it 'returns the audit envelope (resource_id + events) for a freshly created Work' do
    # Create via the HTTP path so WorksController emits the `create`
    # AuditEvent (WorkCreator only logs when an actor_nuid is present).
    created = AtlasRb::Work.create(collection.noid, nuid: admin_nuid)

    envelope = AtlasRb::Resource.history(created['id'], nuid: admin_nuid)

    expect(envelope['resource_id']).to eq(created['id'])
    expect(envelope['events']).to be_an(Array)

    create_event = envelope['events'].find { |e| e['action'] == 'create' }
    expect(create_event).not_to be_nil
    expect(create_event['actor_nuid']).to eq(admin_nuid)
    expect(create_event['resource_type']).to eq('Work')
  end

  it 'returns an empty events array for a resource with no audited actions' do
    # WorkCreator only emits an AuditEvent when an actor_nuid is present;
    # this test-thread create supplies none, so the Work exists with no
    # history. (Direct AuditEvent seeding is avoided on purpose — the
    # server thread holds a separate AR connection and would not see it.)
    work = WorkCreator.call(parent_id: collection.noid)

    envelope = AtlasRb::Resource.history(work.noid, nuid: admin_nuid)

    expect(envelope['resource_id']).to eq(work.noid)
    expect(envelope['events']).to eq([])
  end
end
