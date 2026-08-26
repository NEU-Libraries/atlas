# frozen_string_literal: true

# Resolves the file AuditEvents that attribute a Blob's content revisions.
#
# File events hang off the parent Work — AuditEvent::RESOURCE_TYPES admits
# neither Blob nor FileSet — so a Blob's rows are found by walking Blob →
# FileSet → Work and then filtering that Work's file ledger by blob NOID. The
# walk is what costs: two graph reads plus a ledger read for every Blob.
#
# .for_blobs therefore takes both hops through the batched parent query and
# reads every Work's ledger in one AuditEvent query, so attribution for a whole
# batch costs a fixed number of queries. .for_blob is the same code path for
# one Blob, and issues exactly the queries the unbatched walk used to.
class FileEventLedger < ApplicationService
  # @return [Array<AuditEvent>] this Blob's file events; empty when it has no
  #   resolvable parent Work (an orphan Blob).
  def self.for_blob(blob)
    for_blobs([blob]).fetch(blob.noid, [])
  end

  # @return [Hash{String => Array<AuditEvent>}] Blob NOID => its file events,
  #   oldest first. Blobs with no events (or no resolvable parent Work) are
  #   absent, not empty — callers default.
  def self.for_blobs(blobs)
    new(blobs: blobs).call
  end

  def initialize(blobs:)
    @blobs = Array(blobs).compact
  end

  def call
    return {} if @blobs.empty?

    works = works_by_blob_noid
    return {} if works.empty?

    ledger = ledger_by_work_id(works.values)
    works.each_with_object({}) do |(noid, work), result|
      rows = ledger.fetch(work.id.to_s, []).select { |event| event.payload['blob_noid'] == noid }
      result[noid] = rows if rows.any?
    end
  end

  private

    # Two batched parent reads for the whole set: Blobs to their FileSets (the
    # inverse member_ids direction — a Blob declares no a_member_of), then those
    # FileSets to their Works. A Blob whose graph doesn't land on a Work is
    # dropped: there is no ledger to read for it.
    def works_by_blob_noid
      file_sets = Atlas.query.custom_queries.find_many_parents(resources: @blobs)
                       .select { |_id, parent| parent.is_a?(FileSet) }
      return {} if file_sets.empty?

      works = Atlas.query.custom_queries.find_many_parents(resources: file_sets.values.uniq(&:id))

      @blobs.each_with_object({}) do |blob, result|
        file_set = file_sets[blob.id.to_s]
        work     = file_set && works[file_set.id.to_s]
        result[blob.noid] = work if work.is_a?(Work)
      end
    end

    # Every requested Work's file ledger in one read. Ordered by occurred_at and
    # then id so a batch is deterministic: a same-timestamp tie would otherwise
    # let the seed-revision lookup pick a different row from one run to the next.
    def ledger_by_work_id(works)
      AuditEvent.where(resource_id: works.uniq(&:id).map { |work| work.id.to_s }, change_type: 'file')
                .chronological.order(:id)
                .group_by(&:resource_id)
    end
end
