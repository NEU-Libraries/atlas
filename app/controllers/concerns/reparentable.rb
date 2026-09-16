# frozen_string_literal: true

# Shared re-parent action: PATCH /<type>/:id/parent with { parent_id }, or no
# parent_id to move a Community to the top of the tree. See
# docs/resource-graph.md.
#
# Authorization is TWO-SIDED -- :reparent on both the moved node and the
# destination. Edit rights does not imply it for anyone but :admin and the
# devolved-admin tier.
module Reparentable
  extend ActiveSupport::Concern

  private

    def reparent(klass)
      node = klass.find(params.expect(:id))
      # Before the nil-guard, so check_authorization is satisfied on the
      # not-found path too.
      authorize! :reparent, node
      return head(:not_found) if node.nil?

      destination = reparent_destination
      authorize! :reparent, destination if destination

      Reparenter.call(
        node:              node,
        destination:       destination,
        actor_nuid:        @current_user&.nuid,
        on_behalf_of_nuid: @on_behalf_of
      )

      instance_variable_set("@#{klass.name.underscore}", klass.find(node.id).decorate)
      render :show
    end

    # A given-but-unresolvable parent is a 422 and NOT a 404: the parent is
    # request input, not the addressed resource.
    def reparent_destination
      return nil if params[:parent_id].blank?

      destination = Resource.find(params.expect(:parent_id))
      return destination unless destination.nil?

      raise Exceptions::ReparentError.new('parent_not_found', "parent #{params[:parent_id]} not found")
    end
end
