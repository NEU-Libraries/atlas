# frozen_string_literal: true

namespace :atlas do
  namespace :health do
    desc 'Grade Works green/yellow/red. NOIDS=a,b,c; FIXITY=1 re-hashes the bytes. Read-only.'
    task work: :environment do
      noids = ENV.fetch('NOIDS', '').split(',').map(&:strip).compact_blank
      abort 'give NOIDS=<noid>[,<noid>...]' if noids.empty?

      grades = noids.map do |noid|
        report = WorkHealthCheck.call(noid: noid, fixity: ENV['FIXITY'].present?)
        puts "Work #{noid}  #{report[:grade].upcase}"
        report[:findings].each do |f|
          puts format('    %<severity>-10s %<code>-30s %<subject>-9s %<message>s', **f)
        end
        if (fixity = report[:fixity])
          puts "    fixity: #{fixity[:result] || 'never checked'}, oldest #{fixity[:last_checked_at] || '-'}, " \
               "#{fixity[:never_checked]}/#{fixity[:objects]} objects never checked"
        end
        report[:grade]
      end
      exit(OcflHealth::CLI::EXIT.fetch(%i[red yellow green].find { |g| grades.include?(g) }))
    end
  end
end
