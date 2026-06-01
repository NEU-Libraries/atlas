# frozen_string_literal: true

# Linked-membership endpoints for Works (the DAG overlay): a Work can be a
# "linked member" of additional Collections beyond its one structural home.
#
#   GET    /works/:id/linked_members                 — list linked collection noids
#   POST   /works/:id/linked_members { collection_id } — add a link
#   DELETE /works/:id/linked_members/:collection_id     — remove a link
#
# Two-sided authorization on the mutations: the actor needs edit rights on the
# Work (so you can't litter someone else's Work) AND edit/manage rights on the
# target Collection (so you can't surface a Work you can't see into a
# collection — an info-disclosure path). Both resolve to the same group-ACL
# check (:update); listing only needs the read floor.
#
# All three return the updated list of linked collection noids (the affected
# sub-resource), so atlas_rb and the Cerberus provenance panel see the result
# without a follow-up GET. Permissions are never changed here.
module LinkedMembers
  extend ActiveSupport::Concern

  def linked_members
    work = Work.find(params[:id])
    authorize! :read, work
    return head(:not_found) if work.nil?

    render_linked_members(work)
  end

  def add_linked_member
    work = Work.find(params[:id])
    authorize! :update, work
    return head(:not_found) if work.nil?

    collection = linked_member_target
    authorize! :update, collection

    work = LinkedMemberCreator.call(
      work: work, collection: collection,
      actor_nuid: @current_user&.nuid, on_behalf_of_nuid: @on_behalf_of
    )
    render_linked_members(work)
  end

  def remove_linked_member
    work = Work.find(params[:id])
    authorize! :update, work
    return head(:not_found) if work.nil?

    collection = linked_member_target
    authorize! :update, collection

    work = LinkedMemberRemover.call(
      work: work, collection: collection,
      actor_nuid: @current_user&.nuid, on_behalf_of_nuid: @on_behalf_of
    )
    render_linked_members(work)
  end

  private

    # collection_id is request input (body for POST, path for DELETE); an
    # unresolvable target is a 422, not a 404 (the 404 is the Work itself).
    def linked_member_target
      target = Resource.find(params[:collection_id])
      return target unless target.nil?

      raise Exceptions::LinkedMemberError.new('target_not_found', "collection #{params[:collection_id]} not found")
    end

    def render_linked_members(work)
      ids = Array(work.a_linked_member_of)
      @linked_members = ids.empty? ? [] : Atlas.query.find_many_by_ids(ids: ids).map(&:noid)
      render 'works/linked_members'
    end
end
