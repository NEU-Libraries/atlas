# frozen_string_literal: true

require 'rails_helper'

# /docs is Atlas's only HTML surface, so it is the one page no other spec
# covers. It has failed twice from a single line: a rubocop autocorrect to
# `class DocsController < ApplicationController` (which both trips
# check_authorization and drops the template, because ActionController::API has
# no view layer), and an absolute Scalar spec URL, which resolves outside the
# path prefix of a reverse proxy. These examples pin both.
#
# This is a plain request spec, not an rswag one: /docs is a browser page, not
# an API operation, so it does not belong in openapi/openapi.yaml.
RSpec.describe 'GET /docs' do
  it 'renders the Scalar reference page' do
    get '/docs'

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="api-reference"')
  end

  it 'points Scalar at the spec with a proxy-safe relative URL' do
    get '/docs'

    expect(response.body).to include('data-url="api-docs/openapi.yaml"')
  end

  # A trailing slash moves the browser's base directory down one level, so the
  # same relative path would resolve to /docs/api-docs/openapi.yaml.
  it 'steps the relative URL back up for the trailing-slash form' do
    get '/docs/'

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-url="../api-docs/openapi.yaml"')
  end

  # The pre-normalization path the controller reads carries the query string.
  it 'sees the trailing slash through a query string' do
    get '/docs/?theme=default'

    expect(response.body).to include('data-url="../api-docs/openapi.yaml"')
  end

  # The relative URL is only correct if the Rswag mount answers there.
  it 'serves the spec at the path the page resolves to' do
    get '/api-docs/openapi.yaml'

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('openapi:')
  end
end
