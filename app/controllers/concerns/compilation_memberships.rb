# frozen_string_literal: true

# The six recipe mutations for a Compilation, all one shape: authorize
# :update on the Set, mutate one recipe line, re-render the compilation
# partial. The updated recipe IS the response, so a client's chip counts
# refresh from the shape it already parses. See docs/compilations.md.
#
# Both directions are idempotent: an add is find_or_create_by, and removing
# an absent row is a 200 no-op -- there is nothing for a client to recover
# from.
#
# Recipe churn on an UNPUBLISHED Set emits no audit rows; on a published one
# it does, because that feed reaches outside harvesters.
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
      @compilation = Compilation.find_by!(noid: params.expect(:id))
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
