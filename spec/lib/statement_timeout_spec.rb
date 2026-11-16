# frozen_string_literal: true

require 'rails_helper'

RSpec.describe StatementTimeout do
  let(:connection) { ActiveRecord::Base.connection }

  def current = connection.select_value('SHOW statement_timeout')

  it 'starts from the limit config/database.yml sets' do
    expect(current).to eq('30s')
  end

  it 'lifts the limit inside the block and restores the configured value after it' do
    inside = described_class.lifted(connection) { current }

    expect(inside).to eq('0')
    expect(current).to eq('30s')
  end

  it 'restores the configured value when the block raises' do
    expect { described_class.lifted(connection) { raise ArgumentError } }.to raise_error(ArgumentError)
    expect(current).to eq('30s')
  end
end
