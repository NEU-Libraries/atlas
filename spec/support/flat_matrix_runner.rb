# frozen_string_literal: true

# Sends every row of a flat matrix (spec/support/matrices/flat.rb) as every
# tier, in every state. The including spec defines `build_subjects(state)`,
# which builds the world for the state and returns its subjects by name. A
# refused write must leave the repository unchanged, as in the write matrix.
# See docs/testing.md.
RSpec.shared_examples 'a flat access matrix' do |matrix|
  include_context 'access matrix callers'

  let(:extra_accounts) { matrix::ACCOUNTS }

  after { Atlas.persister.wipe! }

  # A route drawn with `via: [:get, :post]` reports its verb as "GET|POST".
  def flat_route(row)
    key, = row.split('@')
    routes = AccessMatrixFixtures.routes.select { |_, k| k == key }.map(&:first)
    routes.find { |route| route.verb != 'PUT' } || routes.first
  end

  def flat_verb(row, route) = (matrix_options(row)[:verb] || route.verb.split('|').first).downcase

  def matrix_options(row) = @matrix::MATRIX.fetch(row).last

  def flat_request!(row, tier, state)
    options = matrix_options(row)
    route   = flat_route(row)
    params  = options[:params]&.call(@subjects, state) || {}
    send(flat_verb(row, route), flat_path(route, options), params: params, headers: headers_for(tier),
                                                           as: (options[:json] ? :json : nil))
  end

  # :id is the state's subject; a row names any other segment itself.
  def flat_path(route, options)
    named = { id: @subjects[:subject]&.noid }.compact.merge(options[:path]&.call(@subjects) || {})
    named.reduce(route.path.spec.to_s.sub('(.:format)', '')) { |path, (name, value)| path.sub(":#{name}", value.to_s) }
  end

  def repository_fingerprint
    [AuditEvent.count, IdempotencyKey.count, Compilation.count, Compilation.maximum(:updated_at),
     User.count, User.maximum(:updated_at), MaintenanceMode.maximum(:updated_at), FixityResult.count,
     Atlas.query.find_all.map { |resource| [resource.id.to_s, resource.updated_at.to_f] }.sort]
  end

  def flat_check(state, row, tier)
    expected = Array(FlatMatrix.expected(state, tier, matrix_options(row)))
    before = repository_fingerprint unless expected.any? { |status| status.between?(200, 299) }
    flat_request!(row, tier, state)
    fault = ', and changed the repository' if before && repository_fingerprint != before
    return if expected.include?(response.status) && fault.nil?

    "#{row} as #{tier}: expected #{expected.join(' or ')}, got #{response.status}#{fault}"
  end

  matrix::STATES.each do |state|
    it "answers every route as its row says when #{state.to_s.tr('_', ' ')}" do
      @matrix = matrix
      # Every account, and the maintenance row the floor reads lazily, exists
      # before the first cell, or that cell would count its creation as a write.
      [users, system_user, fixity_user, MaintenanceMode.current]
      @subjects = build_subjects(state)
      MaintenanceMode.open!(source: 'operator') if state == :maintenance
      misses = matrix::MATRIX.keys.flat_map do |row|
        matrix::TIERS.filter_map do |tier|
          miss = flat_check(state, row, tier)
          @subjects = build_subjects(state) if matrix_options(row)[:fresh] && response.status.between?(200, 299)
          miss
        end
      end
      expect(misses).to be_empty, "#{misses.size} cells differ:\n  #{misses.join("\n  ")}"
    end
  end
end
