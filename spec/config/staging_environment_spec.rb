# frozen_string_literal: true

require 'rails_helper'

# Guards the pieces that let Atlas boot as `staging`, and the ones that keep
# staging representative of production.
#
# The suite runs as `test`, so it cannot boot the staging environment to check
# it — that verification is `RAILS_ENV=staging bin/rails runner`, run by hand.
# What is pinned here is everything a future edit could quietly remove, since
# each of these failed silently rather than loudly: staging simply ran as some
# other environment, and the cost showed up as latency nobody attributed to it.
RSpec.describe 'the staging environment' do
  def config_file(name)
    Rails.root.join('config', name)
  end

  it 'has an environment file' do
    expect(config_file('environments/staging.rb')).to exist
  end

  # Without this Atlas cannot boot as staging at all: docker-entrypoint.sh runs
  # db:create and db:migrate before the server starts.
  it 'has a database configuration' do
    # Through Rails' own reader, which resolves the ERB and the YAML anchor the
    # file uses — plain YAML.load_file sees neither.
    expect(Rails.application.config.database_configuration).to have_key('staging')
  end

  # Already present before this work, and the reason a real staging environment
  # beats setting RAILS_ENV=production: it selects the staging adapters.
  it 'has a valkyrie adapter configuration' do
    expect(YAML.load_file(config_file('valkyrie.yml'))).to have_key('staging')
  end

  # The reset rebuilds staging's stock fixtures, including the NUID 000000002
  # user that verification depends on. Production is never resettable, so this
  # is what would be lost by running staging as production instead.
  it 'is resettable' do
    expect(MaintenanceController::RESETTABLE_ENVS).to include('staging')
  end

  # The code-loading settings are the entire point. With reloading on, Rails'
  # reload interlock serialises concurrent requests, and Cerberus issues four
  # Atlas reads at once for a Work show page — so the batch becomes a penalty
  # rather than a saving. Asserted by reading the file because the suite runs
  # in another environment and cannot ask the staging config for its values.
  it 'does not reload code' do
    source = config_file('environments/staging.rb').read
    expect(source).to match(/^\s*config\.cache_classes\s*=\s*true$/)
    expect(source).to match(/^\s*config\.eager_load\s*=\s*true$/)
  end

  # Two copies of the cache configuration drift, and a staging cache that
  # differs from production's is a staging environment that has stopped
  # answering the question it exists to answer.
  it 'shares one cache store definition with production' do
    %w[environments/staging.rb environments/production.rb].each do |file|
      expect(config_file(file).read).to include('AtlasCacheStore.redis')
    end
  end

  # rswag-api serves /api-docs, which the Scalar page at /docs fetches.
  # Bundler.require only loads a gem's own groups, so while this sat in
  # :development, :test the unconditional Rswag references in config/routes.rb
  # and config/initializers/rswag_api.rb raised NameError on boot in every
  # other environment — staging and production alike.
  it 'loads rswag-api outside development and test' do
    dependency = Bundler.load.dependencies.find { |d| d.name == 'rswag-api' }
    expect(dependency).to be_present
    expect(dependency.groups).to eq([:default])
  end
end
