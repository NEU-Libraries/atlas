# frozen_string_literal: true

# Optimistic-lock retry for services, which StaleObjectRetry (a controller
# concern) cannot reach. Same budget and backoff. See docs/write-safety.md.
module StaleRetry
  module_function

  # Yields the attempt number, from 0. The block must reload whatever it saves
  # when the attempt is above 0, or it re-saves the same stale token.
  def run(label)
    attempts = 0
    begin
      yield attempts
    rescue Valkyrie::Persistence::StaleObjectError
      attempts += 1
      raise if attempts >= StaleObjectRetry::RETRY_MAX_ATTEMPTS

      Rails.logger.info("StaleRetry: #{label}, retry #{attempts}/#{StaleObjectRetry::RETRY_MAX_ATTEMPTS}")
      pause(attempts)
      retry
    end
  end

  # For a derived write that follows the write a caller asked for, such as a
  # METS rebuild after an upload. Failing the request would make the caller
  # send the upload again, so a conflict that outlasts the retries is logged.
  def settle(label)
    yield
  rescue Valkyrie::Persistence::StaleObjectError => e
    Rails.logger.warn("StaleRetry: #{label} gave up after #{StaleObjectRetry::RETRY_MAX_ATTEMPTS} attempts: " \
                      "#{e.message}")
    nil
  end

  def pause(attempts)
    sleep(rand(0..(StaleObjectRetry::RETRY_BASE_SECONDS * (2**attempts))))
  end
end
