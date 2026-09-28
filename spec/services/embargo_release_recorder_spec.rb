# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EmbargoReleaseRecorder do
  let(:community)  { CommunityCreator.call }
  let(:collection) { CollectionCreator.call(parent_id: community.noid) }
  let(:eastern)    { ActiveSupport::TimeZone[Permissions::EMBARGO_TIME_ZONE] }
  let(:actor)      { instance_double(User, nuid: '000000000') }

  after { Atlas.persister.wipe! }

  def embargoed_work(date)
    work = WorkCreator.call(parent_id: collection.noid)
    work.permissions = work.permissions.merge(embargo: date)
    Atlas.persister.save(resource: work)
  end

  def run_at(time, **)
    described_class.call(actor: actor, event_source: 'job', now: time, **)
  end

  def release_rows(work)
    AuditEvent.for_resource(work.id).where(action: 'release_embargo')
  end

  # The shape an embargo edit leaves: a permissions row whose embargo moved.
  def embargo_change(work, at:, to:)
    AuditEventWriter.record(resource: work, actor_nuid: '000000002', action: 'update',
                            change_type: 'permissions', event_source: 'controller', occurred_at: at,
                            payload: { before: { embargo: nil }, after: { embargo: to } })
  end

  it 'records a lapsed embargo once, dated to the start of the release day in Eastern time' do
    work = embargoed_work('2026-09-01')

    expect(run_at(eastern.parse('2026-09-01 00:30')).map(&:noid)).to eq([work.noid])
    row = release_rows(work).sole
    expect(row.occurred_at).to eq(eastern.parse('2026-09-01 00:00'))
    expect(row).to have_attributes(actor_nuid: '000000000', change_type: 'permissions', event_source: 'job',
                                   resource_type: 'Work', payload: { 'release_date' => '2026-09-01' })
  end

  it 'writes nothing on a repeat run' do
    embargoed_work('2026-09-01')
    run_at(eastern.parse('2026-09-01 00:30'))

    expect(run_at(eastern.parse('2026-09-02 00:30'))).to be_empty
    expect(AuditEvent.where(action: 'release_embargo').count).to eq(1)
  end

  # Solr's stored midnight UTC has passed by 23:30 Eastern the evening before.
  it 'leaves an embargo alone until its Eastern release day begins' do
    work = embargoed_work('2026-09-01')

    expect(run_at(eastern.parse('2026-08-31 23:30'))).to be_empty
    expect(release_rows(work)).to be_empty
  end

  it 'catches up on a lapse within the lookback, and skips one older than it' do
    recent = embargoed_work('2026-09-01')
    old    = embargoed_work('2026-08-01')

    expect(run_at(eastern.parse('2026-09-05 00:30')).map(&:noid)).to eq([recent.noid])
    expect(run_at(eastern.parse('2026-09-05 00:30'), since: Time.utc(2026, 7, 1)).map(&:noid)).to eq([old.noid])
  end

  describe 'the guard' do
    it 'records when the embargo was set before its release moment' do
      work = embargoed_work('2026-09-01')
      embargo_change(work, at: eastern.parse('2026-08-15 10:00'), to: '2026-09-01T00:00:00+00:00')

      expect(run_at(eastern.parse('2026-09-01 00:30')).map(&:noid)).to eq([work.noid])
    end

    it 'skips an embargo set after its own release moment' do
      work = embargoed_work('2026-09-01')
      embargo_change(work, at: eastern.parse('2026-09-03 10:00'), to: '2026-09-01T00:00:00+00:00')

      expect(run_at(eastern.parse('2026-09-04 00:30'))).to be_empty
      expect(release_rows(work)).to be_empty
    end

    # A later grant-only edit leaves the embargo slot unchanged, so it is not
    # an embargo change.
    it 'ignores a later permissions row that did not move the embargo' do
      work = embargoed_work('2026-09-01')
      AuditEventWriter.record(resource: work, actor_nuid: '000000002', action: 'update',
                              change_type: 'permissions', event_source: 'controller',
                              occurred_at: eastern.parse('2026-09-03 10:00'),
                              payload: { before: { embargo: '2026-09-01T00:00:00+00:00', read: [] },
                                         after:  { embargo: '2026-09-01T00:00:00+00:00', read: ['public'] } })

      expect(run_at(eastern.parse('2026-09-04 00:30')).map(&:noid)).to eq([work.noid])
    end
  end

  it 'records a second release when a Work is embargoed again' do
    work = embargoed_work('2026-09-01')
    run_at(eastern.parse('2026-09-01 00:30'))

    embargo_change(work, at: eastern.parse('2026-09-02 10:00'), to: '2026-09-10T00:00:00+00:00')
    reloaded = Work.find(work.noid)
    reloaded.permissions = reloaded.permissions.merge(embargo: '2026-09-10')
    Atlas.persister.save(resource: reloaded)

    run_at(eastern.parse('2026-09-10 00:30'))
    expect(release_rows(work).pluck(:payload)).to contain_exactly({ 'release_date' => '2026-09-01' },
                                                                  { 'release_date' => '2026-09-10' })
  end
end
