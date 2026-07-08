# frozen_string_literal: true

# Every Work beneath a container, at any depth — the read behind
# GET /resources/:id/descendant_works. A WorkDigestQuery (shared gated,
# Solr-only engine) whose container set is the resource's own subtree, giving
# Collections the flatten-to-Works capability Compilations already have via
# CompilationContentsQuery.
#
# The container set is the resource itself plus its ancestor_ids_ssim
# descendants (container_refs([noid]) resolves both — the root via
# alternate_ids_ssim, the descendants via ancestor_ids_ssim). ancestor_ids_ssim
# holds the *entire* ancestor chain (AncestryIndexer), so every descendant
# container at any depth returns from one lookup; ancestor_ids_ssim is on
# Collections/Communities only (Works are deliberately excluded), which is why
# resolution is *containers via ancestor_ids_ssim* then *works via
# a_member_of_ssi*, not a single ancestor_ids_ssim:X AND type:Work query.
#
# Membership is structural (a_member_of_ssi) only — the subtree export the v1
# /collections/:id/pids flatten needed. Sets additionally surface linked
# members by design; a structural export does not, unless the caller opts in
# with include_linked (?include_linked=true), which ORs a_linked_member_of_ssim
# back in. The structural parent is scalar, so no dedup is needed.
class DescendantWorksQuery < WorkDigestQuery
  def self.call(resource:, user:, page: nil, per_page: nil, include_linked: false)
    new(resource: resource, user: user, page: page, per_page: per_page,
        include_linked: include_linked).call
  end

  def initialize(resource:, include_linked: false, **kwargs)
    super(**kwargs)
    @resource       = resource
    @include_linked = include_linked
  end

  private

    def membership_union
      refs = container_refs([@resource.noid])
      return '' if refs.empty?

      list    = refs.join(' ')
      clauses = ["a_member_of_ssi:(#{list})"]
      clauses << "a_linked_member_of_ssim:(#{list})" if @include_linked
      clauses.join(' OR ')
    end
end
