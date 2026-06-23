# frozen_string_literal: true

# Projects a Collection's `personal_root` flag onto its Solr doc as
# personal_root_bsi, so Cerberus can recognise a Person's personal-root
# Collection — a structural container, not content — and exclude it from the
# global catalog (alongside -featured_bsi:true) and rewrite breadcrumbs around
# it. Boolean-as-string, mirroring FeaturedIndexer / TombstoneIndexer's bsi shape.
#
# Collection-only: only Collections are ever personal roots (PersonalRootCreator
# mints one per Person). Empty hash for everything else.
class PersonalRootIndexer
  attr_reader :resource

  def initialize(resource:)
    @resource = resource
  end

  def to_solr
    return {} unless resource.is_a?(Collection)

    { personal_root_bsi: resource.personal_root ? 'true' : 'false' }
  end
end
