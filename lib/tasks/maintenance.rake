# frozen_string_literal: true

# The console door onto the repository-wide read-only window, alongside the
# Cerberus admin hub and the deploy orchestrator. It writes the same row the
# endpoint does, so a window opened here is honoured by every API caller.
#
# This door is a human, so it opens and closes as `operator` — which also means
# it can close a window a deploy left standing.
namespace :maintenance do
  desc 'Open the repository-wide read-only window (MESSAGE=, RETRY_AFTER=)'
  task open: :environment do
    row = MaintenanceMode.open!(source: 'operator', message: ENV.fetch('MESSAGE', nil),
                                retry_after: ENV['RETRY_AFTER']&.to_i)
    puts "read-only window OPEN (source=#{row.source}, since=#{row.since.iso8601})"
  end

  desc 'Close the repository-wide read-only window, whichever door opened it'
  task close: :environment do
    MaintenanceMode.close!(source: 'operator')
    puts 'read-only window CLOSED'
  end

  desc 'Report the repository-wide read-only window'
  task status: :environment do
    row = MaintenanceMode.current
    puts row.read_only ? "OPEN (source=#{row.source}, since=#{row.since.iso8601}, message=#{row.message.inspect})" : 'CLOSED'
  end
end
