# frozen_string_literal: true

module ACLCoverage
  # The five access-control coverage numbers, and every action that breaks a
  # conformance rule. See docs/testing.md for what each number means.
  class Report
    Route  = Struct.new(:verb, :path, :key)
    Metric = Struct.new(:id, :name, :covered, :total) do
      def ratio = total.zero? ? 1.0 : covered.fdiv(total)
      def count? = total.nil?
      def to_s = count? ? covered.to_s : format('%<c>d/%<t>d  %<p>5.1f%%', c: covered, t: total, p: ratio * 100)
    end

    def initialize(routes:, scanner:, registry:)
      @routes   = routes
      @scanner  = scanner
      @registry = registry
    end

    def metrics
      total = actions.size
      [
        Metric.new('M1', 'route inventory', actions.count { |key| classified?(key) }, total),
        Metric.new('M2', 'matrix depth', actions.count { |key| rows.include?(key) }, total),
        Metric.new('M3', 'gate conformance', total - violations_by_action.size, total),
        Metric.new('M4', 'asserted cells', cells, nil),
        Metric.new('M5', 'axis reach', (axes & ACLAxes.ids).size, ACLAxes.ids.size)
      ]
    end

    # Each broken rule, as "action: what is wrong". Stale list entries count,
    # so a reason cannot outlive the action it excused.
    def violations
      violations_by_action.flat_map { |key, problems| problems.map { |problem| "#{key}: #{problem}" } } + stale
    end

    def actions = @actions ||= @routes.map(&:key).uniq.sort

    # Routed actions no matrix crosses with its callers and states.
    def without_row = actions.reject { |key| rows.include?(key) }

    # Routed actions with neither a row nor a written reason.
    def unclassified = actions.reject { |key| classified?(key) }

    def missing_axes = ACLAxes.ids - axes

    private

      def matrices = @registry::ALL.values

      def rows = @rows ||= matrices.flat_map { |m| m::MATRIX.keys.map { |row| row.split('@').first } }.to_set

      def classified?(key) = rows.include?(key) || matrices.any? { |m| m::UNSCOPED.key?(key) }

      def axes = matrices.flat_map { |m| m::AXES }.uniq

      def cells = matrices.sum { |m| m::MATRIX.size * m::TIERS.size * m::STATES.size }

      def violations_by_action
        @violations_by_action ||= actions.filter_map do |key|
          problems = problems_for(key)
          [key, problems] if problems.any?
        end.to_h
      end

      def problems_for(key)
        controller, action = key.split('#')
        calls = @scanner.calls(controller, action)
        return ['the scanner cannot find the action in its controller'] if calls.nil?

        [authorization_problem(key, controller, calls), tombstone_problem(key, controller, calls)].compact
      end

      def authorization_problem(key, controller, calls)
        return nil if @registry::PUBLIC.key?(key)
        return 'calls no authorize! and has no reason in PUBLIC' unless calls.include?(:authorize!)
        return nil if @scanner.guarded?(controller)

        'is outside ApplicationController, so check_authorization never runs: list it in PUBLIC'
      end

      def tombstone_problem(key, controller, calls)
        return nil unless @registry::RESOURCE_CONTROLLERS.include?(controller) && id_keyed?(key)

        gated = calls.intersect?(@registry::TOMBSTONE_GATES.to_set)
        exempt = @registry::TOMBSTONE_EXEMPT.key?(key)
        return 'reaches a tombstone gate, so its TOMBSTONE_EXEMPT reason is stale' if gated && exempt
        return nil if gated || exempt

        'acts on a resource by :id, reaches no tombstone gate, and has no reason in TOMBSTONE_EXEMPT'
      end

      def id_keyed?(key) = @routes.any? { |route| route.key == key && route.path.include?(':id') }

      def stale
        listed = @registry::TOMBSTONE_EXEMPT.keys + @registry::PUBLIC.keys +
                 matrices.flat_map { |m| m::MATRIX.keys.map { |row| row.split('@').first } + m::UNSCOPED.keys }
        (listed.uniq - actions).map { |key| "#{key}: listed, but the application draws no such route" }
      end
  end
end
