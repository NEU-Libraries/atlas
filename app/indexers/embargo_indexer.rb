# frozen_string_literal: true

# Projects a Work's effective embargo state onto its Solr document, so
# Cerberus's catalog can show the red "Embargoed" thumbnail pill and the
# "Contents available <date>" list/gallery notice without a live Atlas call.
# The actual download-withholding gate reads permissions.embargo directly off
# Atlas (AtlasRb::Resource.permissions) — this indexer only feeds those two
# read-only display affordances.
#
# embargoed_bsi mirrors Cerberus's own Embargo.active? (still-future date), so
# the two systems agree on what "currently embargoed" means. Boolean-as-string
# to match TombstoneIndexer/FeaturedIndexer's bsi shape.
#
# Work-only: Permissions#embargo_release_date is welded onto every Resource,
# but Cerberus's Permissions tab only ever surfaces the field for Works.
# Empty hash for everything else; embargo_release_date_dtsi is left absent
# (nil) once there's no embargo set (the setter normalizes "no embargo" to
# '' rather than nil, so #presence is needed to keep an empty string out of
# a Solr date field).
class EmbargoIndexer
  attr_reader :resource

  def initialize(resource:)
    @resource = resource
  end

  def to_solr
    return {} unless resource.is_a?(Work)

    {
      embargo_release_date_dtsi: resource.embargo_release_date.presence,
      embargoed_bsi:             resource.embargoed? ? 'true' : 'false'
    }
  end
end
