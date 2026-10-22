# frozen_string_literal: true

# Answers a dependency outage with a typed 503 rather than a bare 500, so a
# client can tell "Atlas cannot reach its database" from a bug. See
# docs/error-contract.md and docs/availability.md.
module BackendUnavailable
  extend ActiveSupport::Concern

  # `backend_unavailable` is an exact-match wire contract: atlas_rb raises
  # AtlasRb::BackendUnavailableError on it. Do not change it without a
  # contract bump.
  CODE = 'backend_unavailable'
  RETRY_AFTER = 30

  # Faults that mean the filesystem itself has failed. ENOENT and EACCES are
  # absent on purpose: each is as likely to be a wrong path in Atlas's code.
  STORAGE_ERRNOS = [Errno::EIO, Errno::EROFS, Errno::ENOSPC, Errno::EDQUOT,
                    Errno::ESTALE, Errno::ENOTCONN, Errno::EHOSTDOWN].freeze

  included do
    rescue_from ActiveRecord::ConnectionNotEstablished, ActiveRecord::ConnectionFailed do |exception|
      render_backend_unavailable('database', exception)
    end

    # A 4xx from Solr is a query Atlas built wrongly, so it stays a 500.
    rescue_from RSolr::Error::ConnectionRefused, RSolr::Error::Http do |exception|
      raise exception unless solr_outage?(exception)

      render_backend_unavailable('index', exception)
    end

    rescue_from Valkyrie::Storage::OCFL::StorageUnavailable, *STORAGE_ERRNOS do |exception|
      render_backend_unavailable('storage', exception)
    end
  end

  private

    def solr_outage?(exception)
      return true if exception.is_a?(RSolr::Error::ConnectionRefused) || exception.is_a?(RSolr::Error::Timeout)

      exception.response.is_a?(Hash) && exception.response[:status].to_i >= 500
    end

    # The body names the dependency and nothing else: it can reach a guest, so
    # hosts and error text go to the log.
    def render_backend_unavailable(dependency, exception)
      Rails.logger.error("#{dependency} unavailable on #{controller_name}##{action_name}: " \
                         "#{exception.class}: #{exception.message}")
      response.headers['Retry-After'] = RETRY_AFTER.to_s
      render json: {
        error:      CODE,
        dependency: dependency,
        message:    "Atlas cannot reach its #{dependency}; try again shortly"
      }, status: :service_unavailable
    end
end
