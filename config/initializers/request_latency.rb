# frozen_string_literal: true

require Rails.root.join('lib/request_timing').to_s

# Inserted at 0 after cors.rb has inserted Rack::Cors there, so it sits above
# everything and times the whole stack. See docs/read-performance.md.
Rails.application.config.middleware.insert_before 0, RequestTiming
