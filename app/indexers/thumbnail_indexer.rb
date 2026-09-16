# frozen_string_literal: true

# Thumbnail-family Delegate URIs from a resource's :derivative FileSet,
# projected onto the resource's own Solr doc so Blacklight can render row
# thumbnails without re-assembling IIIF URLs from a UUID.
#
# to_solr runs when the PARENT is saved, which is why DelegateCreator and
# DelegateUpdater re-save the parent after mutating a Delegate.
#
# The composite indexer fires on every resource save, so the empty-hash early
# return below is what keeps the fast path fast.
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
