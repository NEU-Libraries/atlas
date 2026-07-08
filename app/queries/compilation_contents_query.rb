# frozen_string_literal: true

# Resolves a Compilation's recipe into the Works it currently denotes — the
# CERES-facing read behind GET /compilations/:id/contents. A WorkDigestQuery
# (shared gated, Solr-only engine); this subclass supplies only the recipe.
#
# The recipe's positive side (#membership_union): works hanging off — or linked
# into — any descendant of an included Collection (ancestor_ids_ssim, plus the
# included Collections themselves), OR individually added works. Its negative
# side (#extra_work_filters): the set-asides. Linked members are ORed in because
# Sets intentionally surface them (a structural export like DescendantWorksQuery
# does not — that is the one deliberate difference between the two).
class CompilationContentsQuery < WorkDigestQuery
  def self.call(compilation:, user:, page: nil, per_page: nil)
    new(compilation: compilation, user: user, page: page, per_page: per_page).call
  end

  def initialize(compilation:, **kwargs)
    super(**kwargs)
    @compilation = compilation
  end

  private

    def membership_union
      clauses = []
      container_refs(@compilation.included_collections).then do |refs|
        next if refs.empty?

        list = refs.join(' ')
        clauses << "a_member_of_ssi:(#{list})"
        clauses << "a_linked_member_of_ssim:(#{list})"
      end
      work_refs = @compilation.included_works.map { |noid| solr_ref(noid) }
      clauses << "alternate_ids_ssim:(#{work_refs.join(' ')})" if work_refs.any?
      clauses.join(' OR ')
    end

    def extra_work_filters
      excluded = @compilation.excluded_works.map { |noid| solr_ref(noid) }
      excluded.any? ? ["-alternate_ids_ssim:(#{excluded.join(' ')})"] : []
    end
end
