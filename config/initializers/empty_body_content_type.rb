# frozen_string_literal: true

require Rails.root.join('lib/empty_body_content_type').to_s

# Innermost, so it sees the controller's own headers. Rails answers a HEAD as
# a GET below Rack::Head, so a HEAD still carries its real length here.
Rails.application.config.middleware.use EmptyBodyContentType
