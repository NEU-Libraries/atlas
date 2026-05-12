# frozen_string_literal: true

# Tombstoned resources return 410 Gone on read-style actions (show, children,
# ancestors) instead of 200. The body is the same tombstone-payload jbuilder
# partial — just with a status code that distinguishes "deliberately gone"
# from "alive" and "never existed."
#
# Including controllers declare the resource class + ivar name they own:
#
#   class WorksController < ApplicationController
#     include TombstoneAware
#     tombstone_aware_for resource_class: Work, var: :work
#   end
#
# The before_action loads the resource into the ivar (so action bodies don't
# re-find it) and halts the chain with a 410 if `tombstoned`.
module TombstoneAware
  extend ActiveSupport::Concern

  included do
    class_attribute :tombstone_resource_class
    class_attribute :tombstone_resource_var
    class_attribute :tombstone_decorate, default: true

    # Each including controller wires the action set itself; this concern's
    # before_action filters by name only.
    # rubocop:disable Rails/LexicallyScopedActionFilter
    before_action :find_and_reject_if_tombstoned,
                  only: %i[show children ancestors]
    # rubocop:enable Rails/LexicallyScopedActionFilter
  end

  class_methods do
    def tombstone_aware_for(resource_class:, var:, decorate: true)
      self.tombstone_resource_class = resource_class
      self.tombstone_resource_var = var
      self.tombstone_decorate = decorate
    end
  end

  private

    def find_and_reject_if_tombstoned
      resource = self.class.tombstone_resource_class.find(params[:id])
      return head(:not_found) if resource.nil?

      resource = resource.decorate if self.class.tombstone_decorate
      instance_variable_set("@#{self.class.tombstone_resource_var}", resource)

      render :show, status: :gone if resource.tombstoned
    end
end
