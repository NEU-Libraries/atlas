# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/acl_coverage').to_s

# The access-control coverage check, run by the full suite so CI holds the
# baseline. The fixture tree below proves each rule can fail. See
# docs/testing.md.
RSpec.describe ACLCoverage do
  describe 'this checkout' do
    let(:report) { described_class.report }

    # The inventory: a new route cannot ship until someone decides who may
    # call it, in every state its subject can be in.
    it 'gives every routed action a row in some matrix, or a reason' do
      expect(report.unclassified).to be_empty,
                                     "Add a row to a matrix in spec/support/matrices for: #{report.unclassified.join(', ')}"
    end

    it 'breaks no conformance rule' do
      expect(report.violations).to be_empty
    end

    it 'holds every number at or above spec/acl_coverage_baseline.json' do
      expect(described_class.regressions(report.metrics, described_class.baseline)).to be_empty
    end
  end

  describe 'the rules' do
    let(:root) { Pathname(Dir.mktmpdir) }

    # A registry with the same shape as ACLMatrices, over one Work-like
    # controller.
    let(:registry) do
      matrix = Module.new
      matrix.const_set(:MATRIX, { 'widgets#show' => [:read] })
      matrix.const_set(:UNSCOPED, {})
      matrix.const_set(:TIERS, %i[guest admin])
      matrix.const_set(:STATES, %i[live])
      matrix.const_set(:AXES, %i[cred_guest])
      Module.new.tap do |mod|
        mod.const_set(:ALL, { read: matrix })
        mod.const_set(:RESOURCE_CONTROLLERS, %w[widgets])
        mod.const_set(:TOMBSTONE_GATES, %i[refuse_tombstoned!])
        mod.const_set(:TOMBSTONE_EXEMPT, {})
        mod.const_set(:PUBLIC, {})
      end
    end

    let(:routes) do
      [ACLCoverage::Report::Route.new('GET', '/widgets/:id', 'widgets#show'),
       ACLCoverage::Report::Route.new('GET', '/widgets/:id/raw', 'widgets#raw')]
    end

    after { FileUtils.rm_rf(root) }

    def controller(name, body)
      path = root.join('app/controllers', "#{name}.rb")
      FileUtils.mkdir_p(path.dirname)
      path.write(body)
    end

    def report = ACLCoverage::Report.new(routes: routes, scanner: ACLCoverage::Scanner.new(root), registry: registry)

    before do
      controller('application_controller', <<~RUBY)
        class ApplicationController < ActionController::API
          private

          def gate!(widget)
            refuse_tombstoned!(widget)
          end
        end
      RUBY
    end

    it 'counts a gate reached through a helper, and fails an action that reaches none' do
      controller('widgets_controller', <<~RUBY)
        class WidgetsController < ApplicationController
          def show
            authorize! :read, widget
            gate!(widget)
          end

          def raw
            authorize! :read, widget
          end
        end
      RUBY

      expect(report.violations).to contain_exactly(match(/\Awidgets#raw: .*no tombstone gate/))
      expect(report.metrics.map { |m| [m.id, m.covered] }).to include(['M2', 1], ['M3', 1])
    end

    it 'fails an action with no authorize!, and one outside ApplicationController' do
      controller('widgets_controller', <<~RUBY)
        class WidgetsController < ActionController::Base
          def show
            authorize! :read, widget
            refuse_tombstoned!(widget)
          end

          def raw
            refuse_tombstoned!(widget)
          end
        end
      RUBY

      expect(report.violations).to contain_exactly(match(/\Awidgets#show: is outside ApplicationController/),
                                                   match(/\Awidgets#raw: calls no authorize!/))
    end

    it 'fails a listed reason that names no drawn route' do
      registry::TOMBSTONE_EXEMPT.then { registry.send(:remove_const, :TOMBSTONE_EXEMPT) }
      registry.const_set(:TOMBSTONE_EXEMPT, { 'widgets#gone' => 'a route since removed' })
      controller('widgets_controller', <<~RUBY)
        class WidgetsController < ApplicationController
          def show = (authorize!(:read, widget) && gate!(widget))
          def raw = (authorize!(:read, widget) && gate!(widget))
        end
      RUBY

      expect(report.violations).to contain_exactly('widgets#gone: listed, but the application draws no such route')
    end

    it 'reports a number below the baseline, and none at or above it' do
      metric = ACLCoverage::Report::Metric.new('M2', 'matrix depth', 1, 2)
      expect(described_class.regressions([metric], { 'M2' => 0.75 })).to contain_exactly(match(/\AM2 .* fell/))
      expect(described_class.regressions([metric], { 'M2' => 0.5 })).to be_empty
    end
  end
end
