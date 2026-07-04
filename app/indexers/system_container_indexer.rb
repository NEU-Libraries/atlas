# frozen_string_literal: true

# Projects a Community's `system_container` flag onto its Solr doc as
# system_container_bsi, so Cerberus can recognise an Atlas auto-provisioned
# structural container (the singleton "People" Community that parents Person
# personal-roots) — not discoverable content — and exclude it from the global
# catalog. Boolean-as-string, mirroring PersonalRootIndexer / FeaturedIndexer's
# bsi shape.
#
# Community-only: only Communities are ever system containers. Empty hash for
# everything else.
class SystemContainerIndexer
  attr_reader :resource

  def initialize(resource:)
    @resource = resource
  end

  def to_solr
    return {} unless resource.is_a?(Community)

    { system_container_bsi: resource.system_container ? 'true' : 'false' }
  end
end
