# frozen_string_literal: true

module Relationships
  extend ActiveSupport::Concern

  included do
    def self.find(id)
      # expect noid
      Valkyrie.config.metadata_adapter.query_service.find_by_alternate_identifier(alternate_identifier: id)
    rescue Valkyrie::Persistence::ObjectNotFoundError
      # try standard valkyrie
      begin
        Valkyrie.config.metadata_adapter.query_service.find_by(id: id)
      rescue Valkyrie::Persistence::ObjectNotFoundError
        nil
      end
    end
  end

  def parent
    begin
      # Accommodate for flipped relationships - member_ids vs a_member_of - via find_inverse_references_by
      result = Valkyrie.config.metadata_adapter.query_service.find_references_by(resource: self, property: :a_member_of)
    rescue KeyError
      #
    end
    if result.blank?
      result = Valkyrie.config.metadata_adapter.query_service.find_inverse_references_by(resource: self,
                                                                                         property: :member_ids)
    end
    # Running with solo parent presumption - may need to revisit this for DRS V1 Smart Collections adaptation
    result.first
  end

  def children
    result = []
    result.concat Valkyrie.config.metadata_adapter.query_service.find_inverse_references_by(
      resource: self, property: :a_member_of
    ).to_a
    result.concat Valkyrie.config.metadata_adapter.query_service.find_members(resource: self).to_a
    result.uniq
  end

  def filtered_children
    children.select { |c| c.is_a?(Collection) || c.is_a?(Work) }.map(&:id).map(&:to_s).to_a
  end
end
