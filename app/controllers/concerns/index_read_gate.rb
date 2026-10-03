# frozen_string_literal: true

# The gate the two Solr debugging endpoints share, and the 502 they answer when
# Solr does not. See docs/solr-indexing.md.
module IndexReadGate
  extend ActiveSupport::Concern

  included do
    rescue_from RSolr::Error::Http, RSolr::Error::ConnectionRefused do
      render_error(:bad_gateway, 'solr_unavailable')
    end
  end

  private

    # Both checks, in this order. The document carries the ACL, the depositor
    # and the in-progress flags, so it must not open what the object's own
    # read gate keeps shut.
    def authorize_index_read!(resource)
      authorize! :read_index, resource&.class || Resource
      authorize! :read, resource || Resource
    end
end
