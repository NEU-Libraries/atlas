# frozen_string_literal: true

# Projects sized-image-derivative URIs onto a resource by traversing
# its `:derivative` FileSet and selecting Delegates by Role. Returns
# nil when the derivative FileSet or the specific tier is absent —
# clients see `null` rather than a missing key.
#
# `#thumbnail_uri` retains the existing single-field projection
# (smallest tier) for backward compatibility with clients that only
# want one URL. New flat fields (thumbnail_2x, preview) on the
# Work/Collection/Community jbuilder partials call
# `#thumbnail_uri_for(role)` to pick a specific tier. Members are
# memoized so a single render touches the persister once even when
# all three projections are emitted.
module ThumbnailProjection
  def thumbnail_uri
    thumbnail_uri_for(Role.thumbnail_image.name)
  end

  def thumbnail_uri_for(use)
    derivative_members.find { |m| m.is_a?(Delegate) && m.use == use }&.uri
  end

  # Seed the projection from a batched read (ThumbnailPreloader), so rendering
  # a set of resources costs a fixed number of queries instead of three per
  # resource. Read-path only, like the other preload seams.
  def preload_derivative_members(list)
    @derivative_members = Array(list)
  end

  def derivative_member_file_set
    children.find { |c| c.is_a?(FileSet) && c.type == Classification.derivative.name }
  end

  private

    def derivative_members
      @derivative_members ||= begin
        fs = derivative_member_file_set
        fs ? Atlas.query.find_members(resource: fs).to_a : []
      end
    end
end
