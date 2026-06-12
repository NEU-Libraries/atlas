# frozen_string_literal: true

# Membership (recipe) mutations for Compilations:
#
#   POST   /compilations/:id/included_collections { collection_id } — include a Collection (transitive)
#   DELETE /compilations/:id/included_collections/:collection_id    — remove an inclusion
#   POST   /compilations/:id/included_works       { work_id }       — include a Work individually
#   DELETE /compilations/:id/included_works/:work_id                — remove an inclusion
#   POST   /compilations/:id/exclusions           { work_id }       — set a Work aside
#   DELETE /compilations/:id/exclusions/:work_id                    — clear a set-aside
#
# Six thin actions, one shape: authorize :update on the Set, mutate one
# recipe line, re-render the compilation partial — the updated recipe is the
# response, so Cerberus chip counts refresh from the same shape it already
# parses. Adds are idempotent (find_or_create_by) and run the join-model
# type validation: a Community / unknown noid is a 422 via the standard
# RecordInvalid rescue. Removes are idempotent too — deleting an absent row
# is a 200 no-op (matches the remove-linked-member temperament; nothing for
# a client to recover from). Recipe churn deliberately emits NO audit rows —
# personal curation, not rights/provenance (settled decision 5).
module CompilationMemberships
  extend ActiveSupport::Concern

  def add_included_collection
    mutate_membership do |comp|
      comp.collection_inclusions.find_or_create_by!(resource_noid: params[:collection_id].to_s)
    end
  end

  def remove_included_collection
    mutate_membership do |comp|
      comp.collection_inclusions.where(resource_noid: params[:collection_id].to_s).delete_all
    end
  end

  def add_included_work
    mutate_membership do |comp|
      comp.work_inclusions.find_or_create_by!(resource_noid: params[:work_id].to_s)
    end
  end

  def remove_included_work
    mutate_membership do |comp|
      comp.work_inclusions.where(resource_noid: params[:work_id].to_s).delete_all
    end
  end

  def add_exclusion
    mutate_membership do |comp|
      comp.exclusions.find_or_create_by!(resource_noid: params[:work_id].to_s)
    end
  end

  def remove_exclusion
    mutate_membership do |comp|
      comp.exclusions.where(resource_noid: params[:work_id].to_s).delete_all
    end
  end

  private

    def mutate_membership
      @compilation = Compilation.find_by!(noid: params[:id])
      authorize! :update, @compilation
      yield @compilation
      render 'compilations/show'
    end
end
