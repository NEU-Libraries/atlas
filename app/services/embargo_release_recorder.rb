# frozen_string_literal: true

# Writes one `release_embargo` audit row for each Work whose embargo has lapsed
# and has no row for that release date yet. Cerberus calls the endpoint on a
# schedule; Atlas owns no job runner. See docs/write-safety.md.
class EmbargoReleaseRecorder < ApplicationService
  # Long enough for a missed night to catch up on the next run.
  LOOKBACK   = 7.days
  BATCH_SIZE = 500

  def initialize(actor:, event_source:, since: nil, now: Time.current)
    @actor        = actor
    @event_source = event_source
    @now          = now
    # Whole days, because Solr stores each release date as midnight UTC.
    @since        = since || (now - LOOKBACK).utc.beginning_of_day
  end

  def call
    candidate_ids.each_slice(BATCH_SIZE).flat_map do |ids|
      Atlas.query.find_many_by_ids(ids: ids).filter_map { |work| record(work) }
    end
  end

  private

    # Solr only nominates. Its stored midnight UTC passes now hours before the
    # Eastern boundary, and the index is derived, so the Postgres resource
    # decides in #record.
    def candidate_ids
      ids = []
      loop do
        docs = solr_page(ids.size)
        ids.concat(docs.pluck('id'))
        return ids if docs.size < BATCH_SIZE
      end
    end

    def solr_page(start)
      params = { q: '*:*', fq: "embargo_release_date_dtsi:[#{@since.utc.iso8601} TO #{@now.utc.iso8601}]",
                 fl: 'id', sort: 'id asc', start: start, rows: BATCH_SIZE }
      Atlas.index_adapter.connection.get('select', params: params).dig('response', 'docs') || []
    end

    def record(work)
      release_date = work.embargo_release_date
      return if release_date.blank? || Permissions.embargo_active?(release_date, now: @now)

      released_at = Permissions.embargo_released_at(release_date)
      day         = released_at.to_date.iso8601
      return if recorded?(work, day) || embargo_changed_after?(work, released_at)

      AuditEventWriter.record(resource: work, actor_nuid: @actor.nuid, action: 'release_embargo',
                              change_type: 'permissions', event_source: @event_source,
                              occurred_at: released_at, payload: { release_date: day })
      work
    end

    # Keyed on the date, not the Work: a Work embargoed again after a release
    # lapses a second time and earns a second row.
    def recorded?(work, day)
      AuditEvent.for_resource(work.id).where(action: 'release_embargo')
                .exists?(["payload->>'release_date' = ?", day])
    end

    # An embargo set after its own release moment was never seen to lapse, and
    # a row dated before the change that set it would read out of order.
    def embargo_changed_after?(work, released_at)
      AuditEvent.for_resource(work.id).where(change_type: 'permissions')
                .where(occurred_at: released_at..)
                .exists?(["payload->'before'->>'embargo' IS DISTINCT FROM payload->'after'->>'embargo'"])
    end
end
