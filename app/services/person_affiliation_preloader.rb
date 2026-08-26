# frozen_string_literal: true

# Resolves the affiliation edges of a page of Persons to NOIDs in one read.
#
# PersonDecorator#affiliated_community_noids already batches one Person's
# handful of edges, but the People index renders a page of Persons, so the
# query count follows the page size. Here the whole page's edges resolve
# together and each row is seeded with its own slice, in its stored order.
#
# Takes decorated Persons — the seam lives on the decorator.
class PersonAffiliationPreloader < ApplicationService
  def self.call(people:)
    new(people: people).call
  end

  def initialize(people:)
    @people = Array(people)
  end

  def call
    seedable = @people.select { |p| p.respond_to?(:preload_affiliated_communities) }
    return @people if seedable.empty?

    noids = noids_by_valkyrie_id(seedable)
    seedable.each do |person|
      person.preload_affiliated_communities(edges(person).filter_map { |id| noids[id] })
    end
    @people
  end

  private

    def edges(person)
      Array(person.affiliated_community_ids).map(&:to_s)
    end

    def noids_by_valkyrie_id(people)
      ids = people.flat_map { |person| edges(person) }.uniq
      return {} if ids.empty?

      Atlas.query.find_many_by_ids(ids: ids).to_h { |r| [r.id.to_s, r.noid] }
    end
end
