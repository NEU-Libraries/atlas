# frozen_string_literal: true

require 'json'
require_relative 'acl_coverage/scanner'
require_relative 'acl_coverage/report'

# Access-control coverage: five numbers computed from the routes, the
# controllers' source and the matrix tables, held against a committed baseline
# that may only rise. Run through `rake acl:coverage` or bin/acl-coverage. See
# docs/testing.md.
module ACLCoverage
  BASELINE = 'spec/acl_coverage_baseline.json'

  def self.report(root: Rails.root)
    require root.join('spec/support/matrices/registry').to_s
    Report.new(routes: routes, scanner: Scanner.new(root), registry: ACLMatrices)
  end

  # Framework routes aside, as the matrices' inventories see them.
  def self.routes
    Rails.application.routes.routes.filter_map do |route|
      controller = route.defaults[:controller]
      next if controller.nil? || controller.start_with?('rails/', 'active_storage/', 'action_mailbox/')

      Report::Route.new(route.verb, route.path.spec.to_s.sub('(.:format)', ''), "#{controller}##{route.defaults[:action]}")
    end
  end

  def self.baseline(root: Rails.root)
    path = root.join(BASELINE)
    path.exist? ? JSON.parse(path.read) : {}
  end

  # Each metric that fell below its baseline, as a message.
  def self.regressions(metrics, baseline)
    metrics.filter_map do |metric|
      floor = baseline[metric.id]
      next if floor.nil?

      value = metric.count? ? metric.covered : metric.ratio
      "#{metric.id} #{metric.name} fell to #{metric} from #{floor}" if value < floor
    end
  end

  # Rounded down, so a baseline never sits above the number it was taken from.
  def self.baseline_values(metrics) = metrics.to_h { |m| [m.id, m.count? ? m.covered : m.ratio.floor(4)] }
end
