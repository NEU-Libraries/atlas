# frozen_string_literal: true

# GET /resources/search: keyword search over the catalog, read straight off
# Solr. The filters copy Cerberus's SearchBuilder for the global catalog, and
# the two must change together — docs/search.md lists each with its source.
class SearchQuery
  include SolrReadGate

  TYPES            = %w[Work Collection Community Person].freeze
  DEFAULT_PER_PAGE = 25
  MAX_PER_PAGE     = 100

  # What Cerberus's result row shows, plus the id fields a client drills in by.
  FIELDS = %w[alternate_ids_ssim internal_resource_tesim title_tsim creator_ssim pub_date_ssim
              thumbnail_ssi in_progress_bsi embargoed_bsi incomplete_bsi].freeze

  Result = Struct.new(:results, :pagination, keyword_init: true)

  class UnknownType < ArgumentError; end

  def self.call(user:, query: nil, type: nil, page: nil, per_page: nil)
    new(user: user, query: query, type: type, page: page, per_page: per_page).call
  end

  def initialize(user:, query:, type:, page:, per_page:)
    raise UnknownType, "unknown type #{type} (expected: #{TYPES.join(', ')})" if type.present? && TYPES.exclude?(type)

    @user     = user
    @query    = query.to_s.strip
    @type     = type.presence
    @page     = [page.to_i, 1].max
    @per_page = per_page.present? ? per_page.to_i.clamp(1, MAX_PER_PAGE) : DEFAULT_PER_PAGE
  end

  def call
    response = Atlas.index_adapter.connection.get('select', params: solr_params)
    docs  = response.dig('response', 'docs') || []
    total = response.dig('response', 'numFound').to_i
    Result.new(results: docs.map { |doc| row(doc) }, pagination: pagination(total))
  end

  private

    # No qf, pf or mm: the core's search handler supplies them, which is what
    # makes the ranking match Cerberus's. A blank q falls through to q.alt.
    def solr_params
      params = { fq: filters, start: (@page - 1) * @per_page, rows: @per_page,
                 sort: 'score desc, created_at_dtsi desc, id asc', fl: FIELDS.join(','),
                 facet: false }
      params[:q] = @query if @query.present?
      params
    end

    def filters
      fq = ['-internal_resource_tesim:(FileSet OR Blob OR Delegate)', '-tombstoned_bsi:true',
            '-featured_bsi:true', '-personal_root_bsi:true', '-system_container_bsi:true']
      gate = read_gate_fq(@user)
      fq << gate if gate
      fq << unfinished_clause unless curator?
      fq << "internal_resource_tesim:#{@type}" if @type
      fq
    end

    # An unfinished deposit is a placeholder, so it stays out of search for all
    # but its depositor and the curators. The *:* is load-bearing: Solr cannot
    # OR a purely negative clause.
    def unfinished_clause
      return '-in_progress_bsi:true' if @user&.nuid.blank?

      "((*:* -in_progress_bsi:true) OR depositor_ssi:#{quoted(@user.nuid)})"
    end

    def curator?
      @user&.admin? || Array(@user&.groups).include?(Permissions::STAFF_EDIT_GROUP)
    end

    def row(doc)
      noid = Array(doc['alternate_ids_ssim']).first.to_s.delete_prefix('id-')
      {
        noid:        noid,
        klass:       Array(doc['internal_resource_tesim']).first,
        title:       Array(doc['title_tsim']).first,
        creators:    Array(doc['creator_ssim']),
        year:        Array(doc['pub_date_ssim']).first,
        thumbnail:   doc['thumbnail_ssi'],
        in_progress: doc['in_progress_bsi'].to_s == 'true',
        embargoed:   doc['embargoed_bsi'].to_s == 'true',
        incomplete:  doc['incomplete_bsi'].to_s == 'true'
      }
    end

    def pagination(total)
      { total: total, page: @page, per_page: @per_page, pages: (total.to_f / @per_page).ceil }
    end
end
