# frozen_string_literal: true

# Access-control coverage. See docs/testing.md.
namespace :acl do
  desc 'Print the access-control coverage numbers and any conformance violation'
  task coverage: :environment do
    require Rails.root.join('lib/acl_coverage').to_s
    report = ACLCoverage.report
    report.metrics.each { |metric| puts format('%<id>-3s %<name>-18s %<value>s', id: metric.id, name: metric.name, value: metric) }
    report.missing_axes.each { |axis| puts "    axis not reached: #{axis}" }
    report.violations.each { |line| puts "FAIL #{line}" }
  end

  namespace :coverage do
    desc 'Fail on a conformance violation or a number below spec/acl_coverage_baseline.json'
    task check: :environment do
      require Rails.root.join('lib/acl_coverage').to_s
      report   = ACLCoverage.report
      failures = report.violations + ACLCoverage.regressions(report.metrics, ACLCoverage.baseline)
      failures.each { |line| warn "FAIL #{line}" }
      abort "#{failures.size} access-control coverage failure(s)" if failures.any?
      puts 'access-control coverage holds its baseline'
    end

    desc 'Raise spec/acl_coverage_baseline.json to the current numbers; it never lowers one'
    task update: :environment do
      require Rails.root.join('lib/acl_coverage').to_s
      report = ACLCoverage.report
      fallen = ACLCoverage.regressions(report.metrics, ACLCoverage.baseline)
      abort "refusing to lower the baseline:\n#{fallen.join("\n")}" if fallen.any?

      Rails.root.join(ACLCoverage::BASELINE).write("#{JSON.pretty_generate(ACLCoverage.baseline_values(report.metrics))}\n")
      puts "wrote #{ACLCoverage::BASELINE}"
    end
  end
end
