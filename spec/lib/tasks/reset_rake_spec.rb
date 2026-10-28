# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# The wiring only: RepositoryReset is stubbed, because the real wipe would empty
# the run's own stores. spec/services/repository_reset_spec.rb covers the wipe.
RSpec.describe 'reset rake tasks' do
  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?('reset:clean') }

  before do
    %w[reset:clean reset:data].each { |name| Rake::Task[name].reenable }
    allow(RepositoryReset).to receive(:call)
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new('development'))
  end

  after { Atlas.persister.wipe! }

  # In-process, so it needs no running server and wipes the same OCFL storage
  # GET /reset does.
  it 'runs RepositoryReset for reset:clean' do
    Rake::Task['reset:clean'].invoke
    expect(RepositoryReset).to have_received(:call).once
  end

  it 'resets, then adds the sample Community, Collection and Work, for reset:data' do
    expect { Rake::Task['reset:data'].invoke }
      .to change { Atlas.query.find_all_of_model(model: Work).count }.by(1)
    expect(RepositoryReset).to have_received(:call).once
  end

  it 'refuses outside development and staging' do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new('production'))

    expect { Rake::Task['reset:clean'].invoke }.to raise_error(/must be development/)
    expect(RepositoryReset).not_to have_received(:call)
  end
end
