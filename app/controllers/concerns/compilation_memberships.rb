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
# a client to recover from).
#
# Recipe churn on an unpublished Set emits NO audit rows — personal curation,
# not rights/provenance. A published Set is different: it is the feed /oai
# hands to outside harvesters, so a Work entering or leaving it is a
# curatorial act with consequences off this system. See #audit_recipe_change!.
module CompilationMemberships
  extend ActiveSupport::Concern

  def add_included_collection
    mutate_membership(line: :included_collections, action: 'link_member') do |comp|
      comp.collection_inclusions.find_or_create_by!(resource_noid: params[:collection_id].to_s)
    end
  end

  def remove_included_collection
    mutate_membership(line: :included_collections, action: 'unlink_member') do |comp|
      comp.collection_inclusions.where(resource_noid: params[:collection_id].to_s).delete_all
    end
  end

  def add_included_work
    mutate_membership(line: :included_works, action: 'link_member') do |comp|
      comp.work_inclusions.find_or_create_by!(resource_noid: params[:work_id].to_s)
    end
  end

  def remove_included_work
    mutate_membership(line: :included_works, action: 'unlink_member') do |comp|
      comp.work_inclusions.where(resource_noid: params[:work_id].to_s).delete_all
    end
  end

  def add_exclusion
    mutate_membership(line: :excluded_works, action: 'link_member') do |comp|
      comp.exclusions.find_or_create_by!(resource_noid: params[:work_id].to_s)
    end
  end

  def remove_exclusion
    mutate_membership(line: :excluded_works, action: 'unlink_member') do |comp|
      comp.exclusions.where(resource_noid: params[:work_id].to_s).delete_all
    end
  end

  private

    def mutate_membership(line:, action:)
      @compilation = Compilation.find_by!(noid: params[:id])
      authorize! :update, @compilation
      before = @compilation.public_send(line)
      yield @compilation
      audit_recipe_change!(line: line, action: action, before: before)
      render 'compilations/show'
    end

    # A published Set is an external commitment: a harvester walks it and
    # copies what it finds into another catalogue, so the definition of what
    # the DRS publishes deserves a durable history. A Compilation carries no
    # OCFL envelope, so the audit log is the only place that history can live.
    #
    # A no-op — re-adding a member, or removing one that is not there — emits
    # nothing, matching the permissions-row convention in Auditable.
    def audit_recipe_change!(line:, action:, before:)
      return unless @compilation.published?

      after = @compilation.public_send(line)
      return if before == after

      audit!(resource: @compilation, action: action, change_type: 'structural',
             payload: { line: line.to_s, before: before, after: after })
    end
end
