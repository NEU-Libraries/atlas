# frozen_string_literal: true

# Resolves a Compilation's recipe into the Works it currently denotes — the
# CERES-facing read behind GET /compilations/:id/contents. A WorkDigestQuery
# (shared gated, Solr-only engine); this subclass supplies only the recipe,
# and the recipe itself comes from CompilationRecipe, which the OAI feed
# resolves through too.
class CompilationContentsQuery < WorkDigestQuery
  include CompilationRecipe

  def self.call(compilation:, user:, page: nil, per_page: nil)
    new(compilation: compilation, user: user, page: page, per_page: per_page).call
  end

  def initialize(compilation:, **kwargs)
    super(**kwargs)
    @compilation = compilation
  end

  private

    def membership_union
      recipe_union(@compilation)
    end

    def extra_work_filters
      recipe_exclusions(@compilation)
    end
end
