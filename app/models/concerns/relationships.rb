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

  def ancestors(resource = nil, pids = [])
    p = if resource.nil?
          parent
        else
          resource.parent
        end
    return pids.reverse if p.nil?

    # Cycle guard: the backbone is a strict tree, so a NOID reappearing in
    # the chain means the data is corrupt. Fail loudly instead of recursing
    # forever — this also protects the AncestryIndexer and the re-parent walk.
    if pids.any? { |noid, _klass| noid == p.noid } || p.noid == noid
      raise Exceptions::AncestorError, "ancestry cycle detected at #{p.noid} while walking #{noid}"
    end

    pids << [p.noid, p.class.to_s]
    ancestors(p, pids)
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
end
