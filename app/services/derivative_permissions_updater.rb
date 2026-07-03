# frozen_string_literal: true

# Replaces a Work's per-asset derivative-visibility policy (see TierVisibility)
# as one coherent object, validating the departmental invariants before it
# persists:
#   1. no tier may be more visible than the Work itself, and
#   2. within the image ladder, visibility narrows as resolution grows
#      (master ⊆ service ⊆ large ⊆ medium ⊆ small) — otherwise a gated `large`
#      rendition is voided by an open full-res / master tier. Non-image media
#      (audio / video / pdf) gate independently: only invariant 1 applies, no
#      cross-media ordering.
#
# Whole-object replace, NOT upsert: the incoming policy is the complete desired
# map; omitted tiers inherit per the cascade in TierVisibility (send `[]` to
# make a tier private). This makes the cross-tier validation deterministic.
# Raises Exceptions::DerivativePermissionsError (a 422) on an unknown tier or a
# violated invariant, before anything is written — nothing is left behind.
class DerivativePermissionsUpdater < ApplicationService
  def initialize(work:, policy:)
    @work   = work
    @policy = policy || {}
  end

  def call
    @work.derivative_permissions = JSON.dump(normalize(@policy))
    validate!
    Atlas.persister.save(resource: @work)
  end

  private

    def normalize(policy)
      policy.to_h.each_with_object({}) do |(key, value), acc|
        tier = key.to_sym
        unless TierVisibility::TIERS.include?(tier)
          raise Exceptions::DerivativePermissionsError.new(:unknown_tier, "unknown derivative tier: #{key}")
        end

        acc[tier] = normalize_groups(value)
      end
    end

    # A group set. A set containing 'public' collapses to ['public'] (the
    # universal audience) so downstream reasoning never sees mixed sets.
    def normalize_groups(value)
      groups = Array(value).map(&:to_s).uniq
      groups.include?('public') ? ['public'] : groups
    end

    # Validate the RESOLVED chain (absent tiers filled by cascade), so a
    # partial policy is checked as it will actually be served.
    def validate!
      validate_image_ladder!
      validate_independent_media!
    end

    # Image ladder: its top (small) ⊆ Work and each step narrows, which by
    # transitivity keeps the whole ladder down to `master` ⊆ Work.
    def validate_image_ladder!
      unless TierVisibility.audience_subset?(@work.resolved_tier_gate(:small), Array(@work.read_groups))
        raise Exceptions::DerivativePermissionsError.new(
          :tier_exceeds_resource, 'a derivative tier cannot be more visible than the Work'
        )
      end

      TierVisibility::IMAGE_LADDER.each_cons(2) do |broader, narrower|
        next if TierVisibility.audience_subset?(@work.resolved_tier_gate(narrower),
                                                @work.resolved_tier_gate(broader))

        raise Exceptions::DerivativePermissionsError.new(
          :tier_ordering_violation, "#{narrower} may be no more visible than #{broader}"
        )
      end
    end

    # Independent media: no ordering, only tier ⊆ Work (an absent key resolves
    # to the Work itself, so this is a no-op for tiers the policy omits).
    def validate_independent_media!
      TierVisibility::INDEPENDENT_MEDIA.each do |tier|
        next if TierVisibility.audience_subset?(@work.resolved_tier_gate(tier), Array(@work.read_groups))

        raise Exceptions::DerivativePermissionsError.new(
          :tier_exceeds_resource, 'a derivative tier cannot be more visible than the Work'
        )
      end
    end
end
