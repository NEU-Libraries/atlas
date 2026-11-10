# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PlannerStats do
  # VACUUM refuses to run inside a transaction block.
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }

  def estimate(table)
    connection.select_rows("SELECT reltuples, relpages FROM pg_class WHERE relname = '#{table}'").first.map(&:to_f)
  end

  def reloptions(table)
    connection.select_value("SELECT array_to_string(reloptions, ',') FROM pg_class WHERE relname = '#{table}'").to_s
  end

  it 'turns autovacuum off for every table it resets' do
    described_class.reset!

    expect(described_class.tables(connection)).to all(satisfy { |table| reloptions(table).include?('autovacuum_enabled=false') })
  end

  def planned_rows(table)
    JSON.parse(connection.select_value("EXPLAIN (FORMAT JSON) SELECT * FROM #{table}")).first.dig('Plan', 'Plan Rows')
  end

  # The state a mid-suite vacuum leaves: no live rows counted, pages kept.
  context 'when a vacuum has recorded zero rows over pages it kept' do
    before do
      # Enough rows that the bad state's one-row estimate falls below half.
      Atlas.persister.save_all(resources: Array.new(20) { Work.new })
      connection.execute("UPDATE pg_class SET reltuples = 0, relpages = 40 WHERE relname = 'orm_resources'")
    end

    after { Atlas.persister.wipe! }

    it 'clears that estimate' do
      described_class.reset!

      reltuples, relpages = estimate('orm_resources')
      expect(reltuples.zero? && relpages.positive?).to be(false)
    end

    it 'leaves the planner counting the rows a spec writes afterwards' do
      described_class.reset!
      actual = connection.select_value('SELECT count(*) FROM orm_resources')

      expect(planned_rows('orm_resources')).to be >= actual / 2
    end
  end
end
