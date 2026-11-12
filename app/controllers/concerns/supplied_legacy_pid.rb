# frozen_string_literal: true

# The `legacy_pid` param on a container or Work create. Sending one is gated on
# its own verb, before anything is created: a pid binds an old public URL to
# the new object. Present but blank still reaches the creator, which refuses
# it. See docs/legacy-pids.md.
module SuppliedLegacyPid
  extend ActiveSupport::Concern

  private

    def supplied_legacy_pid(model)
      return nil unless params.key?(:legacy_pid)

      authorize! :supply_legacy_pid, model
      params[:legacy_pid].to_s
    end
end
