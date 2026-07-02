# frozen_string_literal: true

# Per-tier read-visibility policy for a Work's sized image-derivative
# Delegates. Departments reserve the larger renditions (large / master-zoom)
# to Grouper groups while smaller access copies stay public — "each download
# rendition has its own permissions." The policy is a sparse map of
# tier => [read groups] stored (JSON-encoded) on Work#derivative_permissions;
# this concern resolves the effective gate for any Delegate and answers
# whether it must be authorized rather than linked directly.
#
# The gate is ADVISORY, not an Atlas-enforced byte boundary: a Delegate holds
# only an IIIF `uri` and Atlas never proxies the pixels, so Cerberus and the
# IIIF auth layer are the enforcers. The read path (GET /works/:id/assets,
# /file_sets) surfaces `permission` + `gated` per Delegate for them.
#
# Tier vocabulary reuses the resource read-group tokens (`public`, Grouper
# group names, `[]` = private) so the same groups apply unchanged.
module TierVisibility
  extend ActiveSupport::Concern

  # Delegate `use` (a Role name) -> policy tier. Thumbnail/preview chrome is
  # deliberately absent: it is public by design and never gated.
  TIER_FOR_ROLE = {
    Role.small_image.name  => :small,
    Role.medium_image.name => :medium,
    Role.large_image.name  => :large,
    Role.service_file.name => :service
  }.freeze

  # Most-visible -> least-visible. Visibility must narrow as resolution grows
  # (service ⊆ large ⊆ medium ⊆ small ⊆ the Work), so an absent tier inherits
  # the next lower-resolution tier and `small` falls back to the Work's own
  # read_groups. This makes a sparse policy monotonic by construction — gating
  # only `large` also gates `service`, closing the full-res-zoom leak.
  TIER_ORDER = %i[small medium large service].freeze

  # The stored policy as a symbol-keyed { tier => [read groups] } hash; empty
  # when unset. Malformed JSON (only the updater ever writes it) degrades to
  # empty rather than raising on the read path.
  def derivative_permissions_map
    return {} if derivative_permissions.blank?

    JSON.parse(derivative_permissions, symbolize_names: true)
  rescue JSON::ParserError
    {}
  end

  # Effective read-group set for a Delegate's `use`, after cascade + clamp. A
  # `use` outside TIER_FOR_ROLE (thumbnails, original binaries) resolves to the
  # Work's own read_groups, so it stays ungated when the Work is public.
  def derivative_gate_for(use)
    tier = TIER_FOR_ROLE[use]
    return Array(read_groups) unless tier

    # Clamp to the Work's CURRENT visibility so a later read_groups narrowing
    # can never leave a stale tier resolving broader than its Work.
    TierVisibility.audience_intersect(resolved_tier_gate(tier), Array(read_groups))
  end

  # Whether a Delegate must be routed through an authorizing fetch rather than
  # linked at the IIIF server directly — true unless its audience is public.
  def derivative_gated?(use)
    derivative_gate_for(use).exclude?('public')
  end

  # Cascade-down resolution (pre-clamp): an absent tier inherits the nearest
  # set lower-resolution tier; `small` falls back to the Work's read_groups.
  def resolved_tier_gate(tier)
    map = derivative_permissions_map
    inherited = Array(read_groups)
    TIER_ORDER.each do |t|
      inherited = Array(map[t]) if map.key?(t)
      return inherited if t == tier
    end
    inherited
  end

  # Audience predicates over group-set arrays. `public` is the universal set;
  # group-name subset is conservative-correct (inner ⊆ outer as sets ⇒
  # audience(inner) ⊆ audience(outer), regardless of unknown memberships).
  def self.audience_subset?(inner, outer)
    return true  if Array(outer).include?('public')
    return false if Array(inner).include?('public')

    (Array(inner) - Array(outer)).empty?
  end

  # The portion of `inner`'s audience also visible under `outer` — used to
  # clamp a tier so it never exceeds the Work's current visibility.
  def self.audience_intersect(inner, outer)
    return Array(inner) if Array(outer).include?('public')
    return Array(outer) if Array(inner).include?('public')

    Array(inner) & Array(outer)
  end
end
