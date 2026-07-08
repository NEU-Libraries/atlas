# frozen_string_literal: true

# Shared engine for "resolve a set of containers into the Works they denote,"
# gated and Solr-only — the machinery behind GET /compilations/:id/contents
# (CompilationContentsQuery) and GET /resources/:id/descendant_works
# (DescendantWorksQuery). Nothing is hydrated into Valkyrie resources; digests
# read straight off the result docs, so even a 10k-deep subtree is pure Solr
# with no object materialization.
#
# The template is fixed here; subclasses supply only the recipe:
#   - #membership_union — the positive lucene OR (which containers'/works'
#     members to include). Membership clauses go in fq, never q — the /select
#     handler is edismax with mm/qf, and membership clauses in q silently
#     corrupt. Return blank for "nothing to resolve" (short-circuits to empty).
#   - #extra_work_filters — optional negative/extra fq lines (e.g. a Set's
#     exclusions); defaults to none.
#
# Resolution is always: one lucene work query — member-of any covered
# container, Works only, not tombstoned, ACL-gated — with Solr-side pagination
# (start/rows). The ACL fq mirrors Cerberus SearchBuilder#apply_gated_discovery
# exactly: {!terms f=read_access_group_ssim}public,<user groups>, skipped
# entirely for admins. Cerberus does not gate on embargo state at the discovery
# layer, so neither does this query — the two resolutions must agree on
# visibility.
class WorkDigestQuery
  DEFAULT_PER_PAGE = 25
  MAX_PER_PAGE     = 100

  # Container fan-out bound — matches DescendantCollectionsQuery::ROWS
  # (branching lives among the ~3k collections; works never appear here).
  CONTAINER_ROWS = 10_000

  Result = Struct.new(:digests, :pagination, keyword_init: true)

  def initialize(user:, page:, per_page:)
    @user     = user
    @page     = [page.to_i, 1].max
    @per_page = per_page.present? ? per_page.to_i.clamp(1, MAX_PER_PAGE) : DEFAULT_PER_PAGE
  end

  def call
    union = membership_union
    return Result.new(digests: [], pagination: pagination(0)) if union.blank?

    response = connection.get('select', params: work_query_params(union))
    docs  = response.dig('response', 'docs') || []
    total = response.dig('response', 'numFound').to_i
    Result.new(digests: docs.map { |doc| digest(doc) }, pagination: pagination(total))
  end

  private

    # The set of Works to resolve, as one lucene OR clause. Subclass hook.
    def membership_union
      raise NotImplementedError, "#{self.class} must implement #membership_union"
    end

    # Extra fq lines beyond the standard Work/tombstone/ACL filters (e.g. a
    # Set's set-asides). Subclass hook; none by default.
    def extra_work_filters
      []
    end

    def connection
      Atlas.index_adapter.connection
    end

    # Covered containers as quoted id-<uuid> references (the value shape
    # a_member_of_ssi / a_linked_member_of_ssim store). ancestor_ids_ssim speaks
    # raw noids and carries descendants only, so the roots are unioned in
    # explicitly via alternate_ids_ssim. The uuid hop happens here — the join
    # fields store uuids. A noid that no longer resolves simply matches nothing.
    def container_refs(noids)
      return [] if noids.empty?

      descendants = solr_ids("{!terms f=ancestor_ids_ssim}#{noids.join(',')}")
      roots       = solr_ids("{!terms f=alternate_ids_ssim}#{noids.map { |n| "id-#{n}" }.join(',')}")
      (descendants + roots).uniq.map { |uuid| %("id-#{uuid}") }
    end

    def solr_ids(filter)
      docs = connection.get(
        'select',
        params: { q: '*:*', fq: filter, rows: CONTAINER_ROWS, fl: 'id' }
      ).dig('response', 'docs') || []
      docs.pluck('id')
    end

    def work_query_params(union)
      {
        q:     '*:*',
        fq:    work_filters(union),
        start: (@page - 1) * @per_page,
        rows:  @per_page,
        sort:  'id asc', # stable pagination; fq-only queries have no score
        fl:    'id,alternate_ids_ssim,internal_resource_tesim,title_tsim,thumbnail_ssi'
      }
    end

    def work_filters(union)
      fq = ["(#{union})", 'internal_resource_tesim:Work', '-tombstoned_bsi:true']
      fq.concat(extra_work_filters)
      fq << acl_filter unless @user&.admin?
      fq
    end

    # Cerberus gated-discovery parity — see class comment.
    def acl_filter
      groups = (['public'] + Array(@user&.groups)).uniq
      "{!terms f=read_access_group_ssim}#{groups.join(',')}"
    end

    def solr_ref(noid)
      %("id-#{noid}")
    end

    # Same vocabulary as the find_many digest (resources/find_many.json.jbuilder),
    # read off the Solr doc instead of a hydrated resource. Tombstoned docs
    # are filtered out above, so no flag is carried.
    def digest(doc)
      noid = Array(doc['alternate_ids_ssim']).first.to_s.delete_prefix('id-')
      {
        noid:      noid,
        klass:     Array(doc['internal_resource_tesim']).first,
        title:     Array(doc['title_tsim']).first,
        thumbnail: doc['thumbnail_ssi']
      }
    end

    def pagination(total)
      {
        total:    total,
        page:     @page,
        per_page: @per_page,
        pages:    (total.to_f / @per_page).ceil
      }
    end
end
