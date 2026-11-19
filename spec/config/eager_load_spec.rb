# frozen_string_literal: true

require 'rails_helper'

# Production and staging eager-load the application, and the suite does not: by
# the time a spec runs, spec/support has already loaded whatever a file forgot
# to require. So the check boots a fresh process, the way a deployed Atlas does.
RSpec.describe 'eager loading the application' do
  it 'loads every autoloaded constant without a NameError' do
    output, status = Open3.capture2e({ 'RAILS_ENV' => 'test' }, 'bin/rails', 'zeitwerk:check',
                                     chdir: Rails.root.to_s)

    expect([status.success?, output.lines.last&.strip]).to eq([true, 'All is good!'])
  end
end
