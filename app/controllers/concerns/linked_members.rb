# frozen_string_literal: true

# Linked-membership endpoints for Works (the DAG overlay): a Work can be a
# "linked member" of additional Collections beyond its one structural home.
#
#   GET    /works/:id/linked_members                 — list linked collection noids
#   POST   /works/:id/linked_members { collection_id } — add a link
#   DELETE /works/:id/linked_members/:collection_id     — remove a link
#
# Authorization on the mutations is admin-only: linking a Work into additional
# Collections is a structural mutation of the content graph, and the matching
# Cerberus surface (the /admin actions hub) is admin-gated, so Atlas agrees.
# The check is two-sided (Work AND target Collection) so intent stays
# documented, but :link_member is granted to no role except :admin (via
# `manage :all`) — edit-rights no longer implies it. Listing only needs the
# read floor.
#
# NOTE: this tightens a deliberate prior design. The original linked-members
# plan gated on two-sided edit-rights so a collection manager could self-serve
# linking a permitted Work into their own collection; admin-only removes that
# self-service path (a conscious product reversal, 2026-06-02). See
# gap_reports/atlas_tighten_reparent_linked_member_to_admin.md.
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
    authorize! :link_member, work
    return head(:not_found) if work.nil?

    collection = linked_member_target
    authorize! :link_member, collection

    work = LinkedMemberCreator.call(
      work: work, collection: collection,
      actor_nuid: @current_user&.nuid, on_behalf_of_nuid: @on_behalf_of
    )
    render_linked_members(work)
  end

  def remove_linked_member
    work = Work.find(params[:id])
    authorize! :link_member, work
    return head(:not_found) if work.nil?

    collection = linked_member_target
    authorize! :link_member, collection

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
