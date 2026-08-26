# frozen_string_literal: true

# Counts the SQL a block issues, so an N+1 fix can be asserted as a budget
# rather than described in a commit message. Schema and transaction statements
# are excluded — they are noise a caller cannot control.
module QueryCountHelper
  def count_queries(&block)
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
      next if payload[:name].to_s.match?(/SCHEMA|TRANSACTION/)

      queries << payload[:sql]
    end
    block.call
    queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end

RSpec.configure { |config| config.include QueryCountHelper }
