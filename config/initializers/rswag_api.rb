# frozen_string_literal: true

# Only openapi/public is served. The middleware serves every file under its
# root, so the internal document must stay outside this directory; see
# docs/openapi.md.
Rswag::Api.configure do |c|
  c.openapi_root = Rails.root.join('openapi/public').to_s
end
