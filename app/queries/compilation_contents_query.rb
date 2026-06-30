# frozen_string_literal: true

# Resolves a Compilation's recipe into the Works it currently denotes — the
# CERES-facing read behind GET /compilations/:id/contents. Sibling of
# DescendantCollectionsQuery (same direct-Solr style): nothing is hydrated
# into Valkyrie resources; digests read straight off the result docs.
#
# Resolution, all Solr:
#   1. Container set — every descendant of an included collection
#      (ancestor_ids_ssim speaks raw noids) PLUS the included collections
#      themselves (the descendant field carries descendants only, so the
#      roots are unioned in explicitly via alternate_ids_ssim).
#   2. One lucene work query: member-of/linked-member-of any container, OR
#      individually included; minus set-asides; Works only; not tombstoned;
#      ACL-gated. Membership clauses go in fq, never q — the /select handler
#      is edismax with mm/qf, and membership clauses in q silently corrupt.
#   3. Solr-side pagination (start/rows) — CERES will hit large Sets, so
#      no Pagy-over-array.
#
# The ACL fq mirrors Cerberus SearchBuilder#apply_gated_discovery exactly:
# {!terms f=read_access_group_ssim}public,<user groups>, skipped entirely
# for admins. Cerberus does not gate on embargo state at the discovery
# layer, so neither does this query — the two resolutions must agree on
# visibility.
class CompilationContentsQuery
  DEFAULT_PER_PAGE = 25
  MAX_PER_PAGE     = 100

  # Container fan-out bound — matches DescendantCollectionsQuery::ROWS
  # (branching lives among the ~3k collections; works never appear here).
  CONTAINER_ROWS = 10_000

  Result = Struct.new(:digests, :pagination, keyword_init: true)

  def self.call(compilation:, user:, page: nil, per_page: nil)
    new(compilation: compilation, user: user, page: page, per_page: per_page).call
  end

  def initialize(compilation:, user:, page:, per_page:)
    @compilation = compilation
    @user        = user
    @page        = [page.to_i, 1].max
    @per_page    = per_page.present? ? per_page.to_i.clamp(1, MAX_PER_PAGE) : DEFAULT_PER_PAGE
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

    def connection
      Atlas.index_adapter.connection
    end

    # The recipe's positive side as one lucene OR: works hanging off (or
    # linked into) any covered container, plus the individually-added works.
    def membership_union
      clauses = []
      container_refs.then do |refs|
        next if refs.empty?

        list = refs.join(' ')
        clauses << "a_member_of_ssi:(#{list})"
        clauses << "a_linked_member_of_ssim:(#{list})"
      end
      work_refs = @compilation.included_works.map { |noid| solr_ref(noid) }
      clauses << "alternate_ids_ssim:(#{work_refs.join(' ')})" if work_refs.any?
      clauses.join(' OR ')
    end

    # Covered containers as quoted id-<uuid> references (the value shape
    # a_member_of_ssi / a_linked_member_of_ssim store). The uuid hop happens
    # here — join rows store noids (decision 4). A recipe line whose
    # collection has since been deleted simply matches nothing.
    def container_refs
      noids = @compilation.included_collections
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
      excluded = @compilation.excluded_works.map { |noid| solr_ref(noid) }
      fq << "-alternate_ids_ssim:(#{excluded.join(' ')})" if excluded.any?
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
