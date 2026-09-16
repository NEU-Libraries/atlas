# frozen_string_literal: true

# Retry-with-backoff for transient optimistic-lock conflicts. See
# docs/write-safety.md.
#
# Only wrap an action whose mutation is genuinely idempotent. Do NOT wrap the
# generic update, tombstone/restore or permission removals -- silent retry
# there could clobber a concurrent caller's different intent.
#
# IMPORTANT: the reload must happen INSIDE the retried block. Outside it, the
# retry re-PATCHes with the same stale token and re-raises immediately.
module StaleObjectRetry
  extend ActiveSupport::Concern

  # Bound the added latency at roughly 300ms worst case.
  RETRY_BASE_SECONDS = 0.05
  RETRY_MAX_ATTEMPTS = 3

  private

    def with_stale_object_retry
      attempts = 0
      begin
        yield
      rescue Valkyrie::Persistence::StaleObjectError
        attempts += 1
        raise if stale_retry_exhausted?(attempts)

        # Full jitter, for decorrelation between concurrent retriers.
        sleep(rand(0..(RETRY_BASE_SECONDS * (2**attempts))))
        retry
      end
    end

    # Noisy on purpose: retrying makes a conflict invisible to the caller,
    # but it must stay visible to an operator debugging a coordinator.
    def stale_retry_exhausted?(attempts)
      where = "#{controller_name}##{action_name} for id=#{params[:id]}"
      if attempts >= RETRY_MAX_ATTEMPTS
        Rails.logger.warn("StaleObjectError retry exhausted after #{attempts} attempts on #{where}")
        return true
      end

      Rails.logger.info("StaleObjectError retry #{attempts}/#{RETRY_MAX_ATTEMPTS} on #{where}")
      false
    end
end
