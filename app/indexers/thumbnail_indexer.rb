# frozen_string_literal: true

# Projects thumbnail-family Delegate URIs from a resource's
# `:derivative` FileSet onto the resource's own Solr doc, so Blacklight
# (Cerberus's catalog) can render row thumbnails without re-assembling
# IIIF URLs from a UUID.
#
# Atlas and Cerberus share the same Solr core (blacklight-core), so an
# Atlas-side indexer is enough to feed Cerberus's catalog reads — no
# Cerberus-side Solr write path needed.
#
# Returns an empty hash for resources without a derivative FileSet (Blobs,
# Delegates, FileSets themselves, and resources whose ingest hasn't minted
# derivatives yet). The composite indexer fires for every resource save;
# this keeps the fast path fast.
#
# `to_solr` runs when the *parent* resource is saved — DelegateCreator and
# DelegateUpdater explicitly re-save the parent after mutating a Delegate
# so the parent's Solr doc reprojects with the new URIs.
class ThumbnailIndexer
  attr_reader :resource

  PROJECTED_ROLES = {
    thumbnail_ssi:    -> { Role.thumbnail_image.name },
    thumbnail_2x_ssi: -> { Role.thumbnail_image_2x.name },
    preview_ssi:      -> { Role.preview_image.name }
  }.freeze

  def initialize(resource:)
    @resource = resource
  end

  def to_solr
    fs = derivative_file_set
    return {} unless fs

    members = Atlas.query.find_members(resource: fs).to_a
    PROJECTED_ROLES.transform_values { |role_proc| uri_for(members, role_proc.call) }.compact
  end

  private

    def derivative_file_set
      return nil unless @resource.respond_to?(:children)

      @resource.children.find do |c|
        c.is_a?(FileSet) && c.type == Classification.derivative.name
      end
    end

    def uri_for(members, use)
      members.find { |m| m.is_a?(Delegate) && m.use == use }&.uri
    end
end
