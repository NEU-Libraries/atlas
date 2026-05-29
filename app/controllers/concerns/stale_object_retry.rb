# frozen_string_literal: true

# Retry-with-backoff for transient optimistic-lock conflicts on safe
# (append/idempotent) controller actions.
#
# When two callers PATCH shared resource state within the same lock
# window (e.g. Cerberus's ThumbnailCreationJob and DerivativeCreationJob
# both attaching Delegates to the same FileSet), Valkyrie's optimistic
# locking raises Valkyrie::Persistence::StaleObjectError on the loser.
# For append-style mutations the loser's intent is still valid against
# fresh state, so rescue-reload-retry converges instead of failing —
# this is the pattern the Valkyrie wiki documents under "Optimistic
# Locking".
#
# Only wrap actions whose mutation is genuinely idempotent (re-applying
# the same change against reloaded state yields the same result):
# update_thumbnails, update_image_derivatives, complete. Do NOT wrap the
# generic metadata `update`, tombstone/restore, or permission removals —
# there, silent retry could clobber a concurrent caller's genuinely
# different intent. Those surface the conflict via the 409 envelope in
# ApplicationController instead.
#
# IMPORTANT: the reload must happen inside the retried block. The find
# that re-reads the resource (and the FileSet it references) with a fresh
# optimistic_lock_token is the "reload" half of the pattern; placing it
# outside the block would re-PATCH with the same stale token and re-raise
# immediately.
module StaleObjectRetry
  extend ActiveSupport::Concern

  # Bound the worst-case latency a retried PATCH can add. With the
  # constants below (50ms base, full jitter, exponential 2**n), the two
  # backoff sleeps before exhaustion spread up to ~100 + ~200 = ~300ms
  # worst case. Small enough to stay invisible in API timing budgets;
  # large enough that two retriers don't keep colliding deterministically.
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

        # Full jitter (AWS "Exponential Backoff And Jitter") — best
        # decorrelation between concurrent retriers, avoiding the
        # lockstep-collision thundering herd that deterministic backoff
        # would cause.
        sleep(rand(0..RETRY_BASE_SECONDS * (2**attempts)))
        retry
      end
    end

    # Logs the conflict and reports whether the retry budget is spent.
    # Noisy on purpose: the point of retrying is to make transient
    # conflicts invisible to callers, but they must stay visible to
    # operators debugging a misbehaving coordinator.
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
