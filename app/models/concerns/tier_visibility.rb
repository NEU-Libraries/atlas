# frozen_string_literal: true

# Per-asset read-visibility policy for a Work's downloadable binaries.
# Departments reserve the higher-fidelity renditions — most importantly the
# original/master, and secondarily non-image renditions (PDF / audio / video) —
# to Grouper groups while smaller access copies stay public ("each download
# rendition has its own permissions"). The policy is a sparse map of
# tier => [read groups] stored (JSON-encoded) on Work#derivative_permissions;
# this concern resolves the effective gate for any asset — image-derivative
# Delegate OR held Blob — and answers whether it must be authorized rather than
# fetched directly.
#
# The gate is ADVISORY, not an Atlas-enforced byte boundary. Image Delegates
# hold only an IIIF `uri` and Atlas never proxies the pixels, so Cerberus and
# the IIIF auth layer enforce; for Blobs the enforcing point is Cerberus's
# DownloadsController :read check on the stream. The read path
# (GET /works/:id/assets, /file_sets) surfaces `permission` + `gated` per asset
# for them.
#
# Tier vocabulary reuses the resource read-group tokens (`public`, Grouper
# group names, `[]` = private) so the same groups apply unchanged.
module TierVisibility
  extend ActiveSupport::Concern

  # Image-derivative Delegate `use` (a Role name) -> image-ladder tier.
  # Thumbnail/preview chrome is deliberately absent: it is the open display
  # pipe, public by construction, and never gated.
  TIER_FOR_ROLE = {
    Role.small_image.name  => :small,
    Role.medium_image.name => :medium,
    Role.large_image.name  => :large,
    Role.service_file.name => :service
  }.freeze

  # The image ladder, most-visible -> least-visible with `master` (the original
  # image binary) as the floor. Visibility must narrow as resolution grows
  # (master ⊆ service ⊆ large ⊆ medium ⊆ small ⊆ the Work), so an absent tier
  # inherits the next lower-resolution tier and `small` falls back to the Work's
  # own read_groups. This makes a sparse image policy monotonic by construction
  # — gating only `large` also gates `service` and `master`, closing the
  # full-res / original leak.
  IMAGE_LADDER = %i[small medium large service master].freeze

  # Non-image media gate INDEPENDENTLY — there is no meaningful resolution
  # ordering across a PDF, an audio file and a video, so each is validated only
  # against the Work (tier ⊆ resource) and resolves on its own (an absent key
  # inherits the Work directly, no cascade).
  INDEPENDENT_MEDIA = %i[audio video pdf].freeze

  # The complete accepted policy vocabulary.
  TIERS = (IMAGE_LADDER + INDEPENDENT_MEDIA).freeze

  # Media type ("image" / "audio" / "video") -> policy tier. An image original
  # is the `master` floor; audio/video gate independently. (PDF is keyed on the
  # full mime string, not a media type, so it is handled separately.)
  MEDIA_TIER_BY_MEDIA_TYPE = { 'image' => :master, 'audio' => :audio, 'video' => :video }.freeze

  # Classify a held Blob into its media policy tier from the detected mime
  # type: an image original is the `master`; PDF / audio / video renditions gate
  # independently. Anything else (text, office docs, archives, metadata) has no
  # tier and rides the Work's own read gate.
  def self.media_tier(mime_type)
    return nil if mime_type.blank?
    return :pdf if mime_type == 'application/pdf'

    MEDIA_TIER_BY_MEDIA_TYPE[mime_type.split('/').first]
  end

  # The stored policy as a symbol-keyed { tier => [read groups] } hash; empty
  # when unset. Malformed JSON (only the updater ever writes it) degrades to
  # empty rather than raising on the read path.
  def derivative_permissions_map
    return {} if derivative_permissions.blank?

    JSON.parse(derivative_permissions, symbolize_names: true)
  rescue JSON::ParserError
    {}
  end

  # Effective read-group set for an asset (Delegate or Blob), after cascade +
  # clamp. An asset with no policy tier (thumbnail chrome, a text sidecar)
  # resolves to the Work's own read_groups, so it stays ungated when the Work
  # is public.
  def derivative_gate_for(asset)
    tier = tier_for_asset(asset)
    return Array(read_groups) unless tier

    # Clamp to the Work's CURRENT visibility so a later read_groups narrowing
    # can never leave a stale tier resolving broader than its Work.
    TierVisibility.audience_intersect(resolved_tier_gate(tier), Array(read_groups))
  end

  # Whether an asset must be routed through an authorizing fetch rather than
  # fetched directly (at the IIIF server for Delegates, at Atlas for Blobs) —
  # true unless its audience is public.
  def derivative_gated?(asset)
    derivative_gate_for(asset).exclude?('public')
  end

  # The policy tier an asset falls under: an image Delegate by its Role `use`,
  # a held Blob by its media type. nil for assets outside the vocabulary.
  def tier_for_asset(asset)
    case asset
    when Delegate then TIER_FOR_ROLE[asset.use]
    when Blob     then TierVisibility.media_tier(asset.mime_type)
    end
  end

  # Resolve a tier's read-group set (pre-clamp). Image-ladder tiers cascade
  # down: an absent tier inherits the nearest set lower-resolution tier and
  # `small` falls back to the Work's read_groups. Independent-media tiers do
  # NOT cascade: an absent key inherits the Work directly.
  def resolved_tier_gate(tier)
    map = derivative_permissions_map
    return Array(map.fetch(tier) { read_groups }) unless IMAGE_LADDER.include?(tier)

    inherited = Array(read_groups)
    IMAGE_LADDER.each do |t|
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
