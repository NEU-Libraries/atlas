# frozen_string_literal: true

# Times every action Atlas serves. See docs/read-performance.md.
ActiveSupport::Notifications.subscribe('process_action.action_controller') do |event|
  RequestLatency.record_event(event)
end
