# frozen_string_literal: true

# Shared re-parent action for Works, Collections, and Communities. Each
# controller exposes `PATCH /<type>/:id/parent` whose body is `{ parent_id }`
# (or no parent_id / null for moving a Community to the top of the tree).
#
# Two-sided authorization: the actor needs edit rights on the moved node AND
# on the destination (CanCanCan :reparent, aliased to :update — the group-ACL
# block rule). The structural validation (type, cycle, tombstone) lives in
# Reparenter and surfaces as a 422 via ApplicationController's rescue_from.
module Reparentable
  extend ActiveSupport::Concern

  private

    def reparent(klass)
      node = klass.find(params[:id])
      # Authorize before the nil-guard so check_authorization is satisfied on
      # the not-found path too (mirrors the other member actions). An admin
      # (manage :all) passes the nil check and 404s; a non-admin is denied.
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

    # nil parent_id => move to top of tree (only valid for a Community; the
    # type rule in Reparenter rejects it for Work/Collection). A given-but-
    # unresolvable parent is a 422, not a 404 — the parent is request input.
    def reparent_destination
      return nil if params[:parent_id].blank?

      destination = Resource.find(params[:parent_id])
      raise Exceptions::ReparentError.new('parent_not_found', "parent #{params[:parent_id]} not found") if destination.nil?

      destination
    end
end
