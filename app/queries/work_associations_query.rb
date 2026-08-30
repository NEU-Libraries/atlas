# frozen_string_literal: true

# Reads a Work's typed associations from both ends and returns them keyed by
# predicate, as NOIDs:
#
#   { outbound: { 'is_codebook_for' => ['abc123'] },
#     inbound:  { 'is_transcription_of' => ['def456'] } }
#
# `outbound` is what this Work asserts and is read straight off its own
# attributes. `inbound` is what other Works assert about it, answered by
# find_inverse_references_by — the reverse edge is never stored, so there is
# nothing here that can disagree with the forward one. Predicates with no
# edges are omitted rather than emitted empty.
#
# `ability` is required, not optional. Both ends name a SECOND Work, which the
# caller may have no rights over — an association is a curatorial claim that
# renders on both — so an unfiltered edge list would disclose the NOID of a
# restricted Work through a public one. Making it a required argument means a
# future caller cannot skip the filter by forgetting it.
class WorkAssociationsQuery
  def self.call(work, ability:)
    new(work, ability: ability).call
  end

  def initialize(work, ability:)
    @work    = work
    @ability = ability
  end

  def call
    { outbound: outbound, inbound: inbound }
  end

  private

    def outbound
      Work::ASSOCIATION_TYPES.each_with_object({}) do |predicate, result|
        noids = noids_for(Array(@work[predicate]))
        result[predicate.to_s] = noids if noids.any?
      end
    end

    def inbound
      Work::ASSOCIATION_TYPES.each_with_object({}) do |predicate, result|
        asserters = readable(Atlas.query.find_inverse_references_by(resource: @work, property: predicate).to_a)
        result[predicate.to_s] = asserters.map(&:noid) if asserters.any?
      end
    end

    def noids_for(ids)
      return [] if ids.empty?

      readable(Atlas.query.find_many_by_ids(ids: ids).to_a).map(&:noid)
    end

    def readable(resources)
      resources.select { |resource| @ability.can?(:read, resource) }
    end
end
