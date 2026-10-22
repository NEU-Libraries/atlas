# frozen_string_literal: true

# GET /health: whether Atlas's own dependencies answer. See
# docs/availability.md.
class HealthController < ApplicationController
  # Unauthenticated on purpose: resolving even the guest principal reads the
  # database, so a probe behind require_auth could never report it down.
  skip_before_action :require_auth

  def show
    @health = SystemHealth.report
    render :show, status: SystemHealth.healthy?(@health) ? :ok : :service_unavailable
  end

  private

    def public_endpoint?
      true
    end
end
