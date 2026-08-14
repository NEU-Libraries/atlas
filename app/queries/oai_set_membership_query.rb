# frozen_string_literal: true

# Which published Sets each Work on a page belongs to — the `<setSpec>` lines
# every OAI record header carries.
#
# Membership is a recipe resolved at read time, not a stored edge, so it can
# only be answered by asking Solr. Asking it per Work would be one query per
# record; asking it per published Set is one query per Set, with the page's
# noids as an extra filter. There is one published Set today and the scope
# caps at Compilation::PUBLISHED_LIMIT, so the fan-out is bounded and small.
#
# The recipe comes from CompilationRecipe, the same resolution
# GET /compilations/:id/contents uses, so a record's advertised sets and the
# set's own listing cannot disagree.
class OAISetMembershipQuery
  include SolrRefs
  include CompilationRecipe

  # noid => [setSpec, ...]; a Work in no published Set is simply absent, so
  # callers read it with fetch(noid, []).
  def self.call(noids:)
    new(noids: noids).call
  end

  def initialize(noids:)
    @noids = Array(noids).compact_blank
  end

  def call
    return {} if @noids.empty?

    Compilation.published.each_with_object({}) do |set, acc|
      members_of(set).each { |noid| (acc[noid] ||= []) << set.noid }
    end
  end

  private

    def members_of(compilation)
      union = recipe_union(compilation)
      return [] if union.blank?

      docs = connection.get(
        'select',
        params: { q: '*:*', fq: member_filters(compilation, union),
                  rows: @noids.size, fl: 'alternate_ids_ssim' }
      ).dig('response', 'docs') || []
      docs.map { |doc| Array(doc['alternate_ids_ssim']).first.to_s.delete_prefix('id-') }
    end

    def member_filters(compilation, union)
      fq = ["(#{union})", "alternate_ids_ssim:(#{@noids.map { |n| solr_ref(n) }.join(' ')})"]
      fq.concat(recipe_exclusions(compilation))
    end
end
