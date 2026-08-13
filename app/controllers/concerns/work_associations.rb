# frozen_string_literal: true

# Association endpoints for Works (v1's "associated works"): a typed,
# directed edge from a subordinate Work to the Work it belongs to.
#
#   GET    /works/:id/associations                     — both ends, by type
#   POST   /works/:id/associations { work_id, type }   — assert an edge
#   DELETE /works/:id/associations/:type/:work_id      — retract one
#
# The type sits in the DELETE path rather than a query parameter because it
# is part of the edge's identity: two Works can hold two different edges at
# the same time.
#
# Authorization on the mutations is admin and devolved-admin only, matching
# :link_member rather than edit rights. An association is a curatorial claim
# that shows up on BOTH Works' pages, including one the asserter may have no
# rights over, so the assertion is an operator action. Listing needs only the
# read floor.
#
# All three render the same body, as the linked-member endpoints do, so a
# caller needs no follow-up GET.
module WorkAssociations
  extend ActiveSupport::Concern

  def associations
    work = Work.find(params[:id])
    authorize! :read, work
    return head(:not_found) if work.nil?

    render_associations(work)
  end

  def add_association
    work = Work.find(params[:id])
    authorize! :associate, work
    return head(:not_found) if work.nil?

    work = WorkAssociationCreator.call(
      work: work, target: association_target, type: params[:type],
      actor_nuid: @current_user&.nuid, on_behalf_of_nuid: @on_behalf_of
    )
    render_associations(work)
  end

  def remove_association
    work = Work.find(params[:id])
    authorize! :associate, work
    return head(:not_found) if work.nil?

    work = WorkAssociationRemover.call(
      work: work, target: association_target, type: params[:type],
      actor_nuid: @current_user&.nuid, on_behalf_of_nuid: @on_behalf_of
    )
    render_associations(work)
  end

  private

    # work_id is request input (body for POST, path for DELETE); an
    # unresolvable target is a 422, not a 404 (the 404 is the Work itself).
    def association_target
      target = Resource.find(params[:work_id])
      return target unless target.nil?

      raise Exceptions::WorkAssociationError.new('target_not_found', "work #{params[:work_id]} not found")
    end

    def render_associations(work)
      @associations = WorkAssociationsQuery.call(work)
      render 'works/associations'
    end
end
