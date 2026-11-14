# frozen_string_literal: true

# The search half of the scoped search routes: the keyword, the filters, the
# facets and the named sort that a WorkDigestQuery runs within its scope. It
# checks what the caller sent and turns it into Solr parameters. See
# docs/search.md#searching-within-a-scope.
class ScopedSearch
  include SolrReadGate

  # Facet counts expose values the digest never shows, so a field off this list
  # could read out depositor NUIDs, the ACLs or the workflow flags. Copied from
  # Cerberus's CatalogController facets, and the two must change together.
  FACET_FIELDS = %w[
    type_ssim classification_ssim genre_ssim creator_ssim contributor_ssim
    pub_date_ssim subject_ssim subject_geo_ssim subject_era_ssim
    subject_person_ssim subject_corporate_ssim place_ssim publisher_ssim
    language_ssim photo_category_ssim
  ].freeze

  SORTS = {
    'relevance' => 'score desc, id asc',
    'title'     => 'title_ssi asc, id asc',
    'date'      => 'date_ssi desc, title_ssi asc, id asc'
  }.freeze

  # Three fq lines on purpose. Joined with OR, Lucene reads every clause as
  # MUST_NOT, so the line would read as "any" and run as "all".
  STATE_FILTERS = [
    '-embargo_release_date_dtsi:[NOW TO *]',
    '-in_progress_bsi:true',
    '-incomplete_bsi:true'
  ].freeze

  DEFAULT_FACET_LIMIT = 20
  MAX_FACET_LIMIT     = 100

  class Invalid < ArgumentError; end

  def initialize(query: nil, filters: nil, facets: nil, facet_limit: nil, sort: nil)
    @query       = query.to_s.strip
    @filters     = normalize_filters(filters)
    @facets      = normalize_facets(facets)
    @facet_limit = facet_limit.to_i.positive? ? facet_limit.to_i.clamp(1, MAX_FACET_LIMIT) : DEFAULT_FACET_LIMIT
    @sort        = normalize_sort(sort)
  end

  # Merged over the digest's own parameters, whose scope fq lines stay.
  def solr_params
    { q: @query.presence || '*:*', sort: sort_clause }.merge(facet_params)
  end

  def filter_queries
    STATE_FILTERS + @filters.map { |field, values| "#{field}:(#{values.map { |v| quoted(v) }.join(' OR ')})" }
  end

  # Solr answers each field as a flat [value, count, value, count] list.
  def facet_counts(response = nil)
    fields = response&.dig('facet_counts', 'facet_fields') || {}
    @facets.index_with do |field|
      Array(fields[field]).each_slice(2).map { |value, count| { value: value, count: count.to_i } }
    end
  end

  private

    def sort_clause
      return SORTS.fetch(@sort) if @sort

      @query.present? ? SORTS['relevance'] : 'id asc'
    end

    def facet_params
      return { facet: false } if @facets.empty?

      { facet: true, 'facet.field': @facets, 'facet.limit': @facet_limit, 'facet.mincount': 1 }
    end

    def normalize_filters(filters)
      return {} if filters.blank?
      raise Invalid, 'f must be keyed by field, as f[field][]=value' unless filters.respond_to?(:each_pair)

      filters.each_pair.with_object({}) do |(field, values), out|
        check_field!(field.to_s, 'f')
        values = strings(values, "f[#{field}]").compact_blank
        out[field.to_s] = values.uniq if values.any?
      end
    end

    def normalize_facets(facets)
      strings(facets, 'facet').compact_blank.uniq.each { |field| check_field!(field, 'facet') }
    end

    def normalize_sort(sort)
      return nil if sort.blank?
      return sort.to_s if SORTS.key?(sort.to_s)

      raise Invalid, "unknown sort #{sort} (expected: #{SORTS.keys.join(', ')})"
    end

    def strings(value, name)
      list = value.is_a?(Array) ? value : [value].compact
      raise Invalid, "#{name} must be a string or a list of strings" unless list.all?(String)

      list.map(&:strip)
    end

    def check_field!(field, name)
      return if FACET_FIELDS.include?(field)

      raise Invalid, "#{name} names an unknown field #{field} (expected: #{FACET_FIELDS.join(', ')})"
    end
end
