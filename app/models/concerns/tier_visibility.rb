# frozen_string_literal: true

# Per-asset read-visibility policy for a Work's downloadable binaries: the
# sparse { tier => [read groups] } map on Work#derivative_permissions, resolved
# for any asset. See docs/authorization.md for the policy, the cascade argument
# and where the gate is actually enforced.
#
# Atlas enforces the gate on Blob bytes (WithheldBytesGate). It never proxies
# image pixels, so for Delegates it only surfaces `permission` and `gated` per
# asset, and Cerberus and the IIIF auth layer enforce.
module TierVisibility
  extend ActiveSupport::Concern

  # Image-derivative Delegate `use` (a Role name) -> image-ladder tier.
  # Thumbnail/preview chrome is absent on purpose: it is the open display pipe
  # and is never gated.
  TIER_FOR_ROLE = {
    Role.small_image.name  => :small,
    Role.medium_image.name => :medium,
    Role.large_image.name  => :large,
    Role.service_file.name => :service
  }.freeze

  # Most-visible -> least-visible, with `original` (the deposited image) as the floor.
  # Order is load-bearing: resolved_tier_gate walks it so an absent tier
  # inherits the next lower-resolution one, which is what makes a sparse
  # policy monotonic. Reordering this opens the full-resolution leak.
  IMAGE_LADDER = %i[small medium large service original].freeze

  # No resolution ordering exists across these, so each is validated only
  # against the Work and an absent key inherits the Work directly.
  INDEPENDENT_MEDIA = %i[audio video pdf archive spreadsheet structured_text presentation text generic].freeze

  # The complete accepted policy vocabulary.
  TIERS = (IMAGE_LADDER + INDEPENDENT_MEDIA).freeze

  MEDIA_TIER_BY_MEDIA_TYPE = { 'image' => :original, 'audio' => :audio, 'video' => :video }.freeze

  # Keyed on the classification a FileSet already carries, so the two
  # vocabularies cannot drift apart.
  TIER_BY_CLASSIFICATION = {
    Classification.archive.name         => :archive,
    Classification.spreadsheet.name     => :spreadsheet,
    Classification.structured_text.name => :structured_text,
    Classification.presentation.name    => :presentation,
    Classification.text.name            => :text
  }.freeze

  # A caption serves the player, not the reader, so restricting Documents or
  # Other files must not strip a video of its captions.
  CAPTION_MIME_TYPES = %w[text/vtt application/x-subrip].freeze

  # PDF classifies as text, so it must be answered before the classification
  # lookup. A caption has no tier and rides the Work's own gate.
  def self.media_tier(mime_type)
    return nil if mime_type.blank? || CAPTION_MIME_TYPES.include?(mime_type)
    return :pdf if mime_type == 'application/pdf'

    MEDIA_TIER_BY_MEDIA_TYPE[mime_type.split('/').first] ||
      TIER_BY_CLASSIFICATION.fetch(MimeHelper.classification_for(mime_type).name, :generic)
  end

  # Malformed JSON degrades to empty rather than raising: this sits on the read
  # path and only the updater ever writes the column.
  def derivative_permissions_map
    return {} if derivative_permissions.blank?

    JSON.parse(derivative_permissions, symbolize_names: true)
  rescue JSON::ParserError
    {}
  end

  def derivative_gate_for(asset)
    tier = tier_for_asset(asset)
    return Array(read_groups) unless tier

    # Clamp to the Work's CURRENT visibility so a later read_groups narrowing
    # can never leave a stale tier resolving broader than its Work.
    TierVisibility.audience_intersect(resolved_tier_gate(tier), Array(read_groups))
  end

  # Gated means a client must be authorized for the asset rather than fetch it
  # directly. An active embargo withholds every held binary and every gated
  # image tier whatever the tier's audience, as WithheldBytesGate and the asset
  # partial enforce; thumbnails stay open. See docs/authorization.md.
  def derivative_gated?(asset)
    embargo_gates?(asset) || derivative_gate_for(asset).exclude?('public')
  end

  def embargo_gates?(asset)
    embargoed? && (asset.is_a?(Blob) || TIER_FOR_ROLE.key?(asset.use))
  end

  def tier_for_asset(asset)
    case asset
    when Delegate then TIER_FOR_ROLE[asset.use]
    when Blob     then TierVisibility.media_tier(asset.mime_type)
    end
  end

  # Pre-clamp. Image-ladder tiers cascade down; independent-media tiers do not.
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

  # `public` is the universal set. Group-name subset is conservative-correct:
  # inner ⊆ outer as sets ⇒ audience(inner) ⊆ audience(outer), whatever the
  # unknown memberships are.
  def self.audience_subset?(inner, outer)
    return true  if Array(outer).include?('public')
    return false if Array(inner).include?('public')

    (Array(inner) - Array(outer)).empty?
  end

  def self.audience_intersect(inner, outer)
    return Array(inner) if Array(outer).include?('public')
    return Array(outer) if Array(inner).include?('public')

    Array(inner) & Array(outer)
  end
end
