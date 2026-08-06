# frozen_string_literal: true

# Renders the human-facing API reference at /docs using Scalar.
# Inherits from ActionController::Base (not ApplicationController) for two
# reasons: the JSON-only :require_auth and check_authorization chain must not
# gate the docs page, and ActionController::API carries no view layer, so an
# ApplicationController subclass renders this ERB template as an empty body.
# The cop stays off because its autocorrect to ApplicationController takes the
# page down both ways.
class DocsController < ActionController::Base # rubocop:disable Rails/ApplicationController
  SPEC_PATH = 'api-docs/openapi.yaml'

  # The spec URL stays relative so the page also works behind a reverse proxy
  # that rewrites a path prefix: staging serves Atlas under /api, and an
  # absolute /api-docs/... resolves against the site root, outside that prefix.
  # The browser resolves a relative path against the document directory, which
  # a trailing slash moves down one level — hence the step back up.
  def show
    @spec_url = trailing_slash? ? "../#{SPEC_PATH}" : SPEC_PATH
    render :show, layout: false
  end

  private

    # ActionDispatch::RouteSet#call normalizes PATH_INFO before it dispatches,
    # so request.path never carries the trailing slash that the browser
    # resolves the spec URL against. The pre-normalization path does.
    def trailing_slash?
      request.original_fullpath.split('?').first.end_with?('/')
    end
end
