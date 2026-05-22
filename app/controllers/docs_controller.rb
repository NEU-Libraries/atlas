# frozen_string_literal: true

# Renders the human-facing API reference at /docs using Scalar.
# Inherits from ActionController::Base (not ApplicationController) so the
# JSON-only :require_auth chain does not gate the docs page.
class DocsController < ApplicationController
  def show
    render :show, layout: false
  end
end
