# frozen_string_literal: true

module Relationships
  extend ActiveSupport::Concern

  included do
    def self.find(id)
      # expect noid
      Atlas.query.find_by_alternate_identifier(alternate_identifier: id)
    rescue Valkyrie::Persistence::ObjectNotFoundError
      # try standard valkyrie
      begin
        Atlas.query.find_by(id: id)
      rescue Valkyrie::Persistence::ObjectNotFoundError
        nil
      end
    end
  end

  def parent
    begin
      # Accommodate for flipped relationships - member_ids vs a_member_of - via find_inverse_references_by
      result = Atlas.query.find_references_by(resource: self, property: :a_member_of)
    rescue KeyError
    end
    if result.blank?
      result = Atlas.query.find_inverse_references_by(resource: self,
                                                      property: :member_ids)
    end
    # a_member_of is a scalar single parent (and member_ids resolves one
    # parent per child), so there is at most one reference. find_references_by
    # is inherently plural, so .first unwraps the single result.
    result.first
  end

  # Lightweight [noid, class-name] pairs, root-first. The historical contract
  # the AncestryIndexer (ancestor_ids_ssim) and any positional-tuple consumer
  # depend on. Derived from the single walk in `ancestor_resources` — the
  # parents are already materialized there, so this costs nothing extra.
  def ancestors
    ancestor_resources.map { |r| [r.noid.to_s, r.class.to_s] }
  end

  # The same chain as `ancestors`, but carrying each ancestor's title under
  # named keys — so a consumer building breadcrumbs (Cerberus) gets the title
  # that was already loaded here, instead of issuing one HTTP round-trip per
  # ancestor to re-fetch it. plain_title mirrors the resource's own title
  # field in the jbuilder partials; it lives on the decorator.
  def ancestor_chain
    ancestor_resources.map do |r|
      { noid: r.noid.to_s, klass: r.class.to_s, title: r.decorate.plain_title }
    end
  end

  # Collections/communities whose ancestor chain includes this resource —
  # the reverse of `ancestors`, answered by a single Solr lookup against
  # ancestor_ids_ssim rather than a subtree walk. Returns sub-communities as
  # well as collections (both carry the field); the name follows the plan.
  # Used by the re-parent cycle guard and the maintenance cascade.
  def descendant_collections
    DescendantCollectionsQuery.call(self)
  end

  def children
    result = []
    result.concat Atlas.query.find_inverse_references_by(
      resource: self, property: :a_member_of
    ).to_a
    result.concat Atlas.query.find_members(resource: self).to_a
    result.uniq
  end

  def filtered_children
    children.select { |c| c.is_a?(Community) || c.is_a?(Collection) || c.is_a?(Work) }.map(&:noid).map(&:to_s).to_a
  end

  def live_children?
    children.any? { |c| (c.is_a?(Community) || c.is_a?(Collection) || c.is_a?(Work)) && !c.tombstoned }
  end

  private

    # Walk parent links to the root, collecting the fully materialized resource
    # objects once. Returned root-first (matching the historical `pids.reverse`
    # order: [root, …, grandparent, parent]) so both `ancestors` and
    # `ancestor_chain` derive their shapes from a single walk, never twice.
    def ancestor_resources(resource = nil, resources = [])
      p = (resource || self).parent
      return resources.reverse if p.nil?

      # Cycle guard: the backbone is a strict tree, so a NOID reappearing in
      # the chain means the data is corrupt. Fail loudly instead of recursing
      # forever — this also protects the AncestryIndexer and the re-parent walk.
      if resources.any? { |r| r.noid == p.noid } || p.noid == noid
        raise Exceptions::AncestorError, "ancestry cycle detected at #{p.noid} while walking #{noid}"
      end

      resources << p
      ancestor_resources(p, resources)
    end
end
