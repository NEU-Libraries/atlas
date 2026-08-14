# frozen_string_literal: true

# One page of the OAI-PMH feed, straight off Solr.
#
# A sibling of WorkDigestQuery rather than a subclass: it shares the ref
# vocabulary and the recipe, but every other decision differs. It sorts by
# datestamp, pages with a cursorMark instead of start/rows, carries the whole
# MODS document in `fl`, keeps tombstoned records (they become
# `<header status="deleted">`), and gates on the literal `public` group rather
# than a caller's — a harvest feed has no authenticated principal, so the
# public group is the whole of its visibility.
#
# Paging is Solr's cursorMark, which holds its cost flat however deep a
# harvester walks; `start`/`rows` degrades on a large repository. It needs a
# total sort order, which `oai_datestamp_dtsi asc, id asc` gives (id is
# unique), and that order is also the one harvesters expect.
#
# Two deliberate non-filters:
#   - `incomplete` Works stay IN. The flag marks a degraded but readable
#     record and, by design, flags without hiding — dropping them would make
#     records vanish from Digital Commonwealth after a pipeline failure.
#   - tombstoned Works stay IN, so a withdrawal is reportable. A Work that
#     loses its public read group instead just disappears, which is why the
#     provider declares `deletedRecord` as `transient`.
#
# `-in_progress_bsi:true` is negative on purpose: a document indexed before
# the field existed carries no value, and `in_progress_bsi:false` would drop
# it silently. (in_progress defaults to true and flips at
# POST /works/:id/complete.)
class OAIWorksQuery
  include SolrRefs
  include CompilationRecipe

  # Fields a record page needs. mods_xml_ss is the big one — a stored-only
  # string holding the whole preservation MODS document, which is why
  # ListRecords pages smaller than ListIdentifiers.
  RECORD_FIELDS     = 'id,alternate_ids_ssim,oai_datestamp_dtsi,tombstoned_bsi,mods_xml_ss'
  IDENTIFIER_FIELDS = 'id,alternate_ids_ssim,oai_datestamp_dtsi,tombstoned_bsi'

  Result = Struct.new(:docs, :cursor_mark, :total, keyword_init: true)

  # rubocop:disable Metrics/ParameterLists
  # Each kwarg is one independent axis of a list request — which set, which
  # date window, where in the walk, how big a page, how much of each record —
  # and they come from five different places in OAI::Request. A single options
  # hash would hide that contract.
  #
  # `compilation` nil means the whole repository: a bare ListRecords with no
  # `set` argument, which the protocol requires a repository to answer.
  def self.call(compilation: nil, from: nil, until_time: nil, cursor_mark: '*', rows: 50, metadata: true)
    new(compilation: compilation, from: from, until_time: until_time,
        cursor_mark: cursor_mark, rows: rows, metadata: metadata).call
  end

  # The datestamp of the oldest harvestable record — Identify's
  # earliestDatestamp. Nil when the repository holds nothing yet.
  def self.earliest_datestamp
    new(rows: 1).earliest_datestamp
  end

  # One record by NOID, under exactly the same membership rules as a list
  # page: a Work that is private, still in progress, or carries no datestamp
  # is not in this repository at all, and the caller answers idDoesNotExist
  # rather than leaking that it exists.
  def self.find(noid, metadata: true)
    new(rows: 1, metadata: metadata).find(noid)
  end

  def initialize(compilation: nil, from: nil, until_time: nil, cursor_mark: '*', rows: 50, metadata: true)
    # rubocop:enable Metrics/ParameterLists
    @compilation = compilation
    @from        = from
    @until_time  = until_time
    @cursor_mark = cursor_mark.presence || '*'
    @rows        = rows
    @metadata    = metadata
  end

  def call
    union = @compilation && recipe_union(@compilation)
    return Result.new(docs: [], cursor_mark: @cursor_mark, total: 0) if @compilation && union.blank?

    response = connection.get('select', params: query_params(union))
    Result.new(
      docs:        response.dig('response', 'docs') || [],
      cursor_mark: response['nextCursorMark'],
      total:       response.dig('response', 'numFound').to_i
    )
  end

  def find(noid)
    docs = connection.get(
      'select',
      params: { q: '*:*', fq: base_filters + ["alternate_ids_ssim:#{solr_ref(noid)}"],
                rows: 1, fl: @metadata ? RECORD_FIELDS : IDENTIFIER_FIELDS }
    ).dig('response', 'docs') || []
    docs.first
  end

  def earliest_datestamp
    docs = connection.get(
      'select',
      params: { q: '*:*', fq: base_filters, rows: 1, fl: 'oai_datestamp_dtsi',
                sort: 'oai_datestamp_dtsi asc' }
    ).dig('response', 'docs') || []
    docs.first&.fetch('oai_datestamp_dtsi', nil)
  end

  private

    def query_params(union)
      {
        q:          '*:*',
        fq:         filters(union),
        rows:       @rows,
        sort:       'oai_datestamp_dtsi asc, id asc',
        cursorMark: @cursor_mark,
        fl:         @metadata ? RECORD_FIELDS : IDENTIFIER_FIELDS
      }
    end

    def filters(union)
      fq = base_filters
      if union.present?
        fq = ["(#{union})"] + fq
        fq.concat(recipe_exclusions(@compilation))
      end
      fq << datestamp_range if @from || @until_time
      fq
    end

    # A record must be a Work, publicly readable, and finished depositing.
    # Every record also needs a datestamp: a Work indexed before OAIIndexer
    # shipped has none, and a record with no datestamp cannot be harvested
    # incrementally, so it stays out until the reindex backfill reaches it.
    def base_filters
      ['internal_resource_tesim:Work',
       'read_access_group_ssim:public',
       '-in_progress_bsi:true',
       'oai_datestamp_dtsi:[* TO *]']
    end

    # Both bounds are inclusive, which is what OAI-PMH specifies. `from` and
    # `until` arrive already normalized to UTC by OAI::Request.
    def datestamp_range
      "oai_datestamp_dtsi:[#{solr_time(@from)} TO #{solr_time(@until_time)}]"
    end

    def solr_time(time)
      time ? time.utc.iso8601 : '*'
    end
end
