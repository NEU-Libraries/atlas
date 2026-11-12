# frozen_string_literal: true

# Which object a v1 pid became, so Cerberus can redirect an old URL. See
# docs/legacy-pids.md.
class LegacyPidsController < ApplicationController
  # A caller who may not read the holder gets the same 404 as an unknown pid,
  # so the lookup never hands out the NOID of an object it would refuse. A
  # tombstoned holder is answered and flagged: the old URL must still land on
  # the tombstone page.
  #
  # Never cached: a reset re-uses NOIDs, and a cached answer would outlive the
  # object it names.
  def show
    authorize! :read, Resource
    @resource = LegacyPid.holder(params.expect(:pid))
    head(:not_found) unless @resource && can?(:read, @resource)
  end
end
