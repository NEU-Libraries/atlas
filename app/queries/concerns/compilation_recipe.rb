# frozen_string_literal: true

# A Compilation's three-line recipe — include-collection (transitive),
# include-work, exclude-work — expressed as Solr filter clauses.
#
# Two consumers resolve the same recipe for different audiences:
# CompilationContentsQuery (GET /compilations/:id/contents, gated per caller,
# start/rows paging) and OAIWorksQuery (the /oai feed, public-only, cursorMark
# paging). They must agree on membership to the record — the OAI cut-over
# acceptance check compares one against the other — so the recipe lives here
# and neither owns a private copy.
#
# Linked members are ORed in because Sets intentionally surface them; a
# structural export like DescendantWorksQuery deliberately does not.
module CompilationRecipe
  extend ActiveSupport::Concern
  include SolrRefs

  private

    # The positive side, as one lucene OR clause: works hanging off — or linked
    # into — any descendant of an included Collection (plus the included
    # Collections themselves), OR works added individually. Blank means the
    # recipe denotes nothing, which callers short-circuit on.
    def recipe_union(compilation)
      clauses = []
      container_refs(compilation.included_collections).then do |refs|
        next if refs.empty?

        list = refs.join(' ')
        clauses << "a_member_of_ssi:(#{list})"
        clauses << "a_linked_member_of_ssim:(#{list})"
      end
      work_refs = compilation.included_works.map { |noid| solr_ref(noid) }
      clauses << "alternate_ids_ssim:(#{work_refs.join(' ')})" if work_refs.any?
      clauses.join(' OR ')
    end

    # The negative side: the set-asides, as fq lines.
    def recipe_exclusions(compilation)
      excluded = compilation.excluded_works.map { |noid| solr_ref(noid) }
      excluded.any? ? ["-alternate_ids_ssim:(#{excluded.join(' ')})"] : []
    end
end
