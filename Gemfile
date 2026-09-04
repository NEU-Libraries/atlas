# frozen_string_literal: true

source 'https://rubygems.org'
git_source(:github) { |repo| "https://github.com/#{repo}.git" }

ruby '~> 3.4'

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem 'rails', '~> 8.1.3'

# Use postgresql as the database for Active Record
gem 'pg', '~> 1.1'

# Use the Puma web server [https://github.com/puma/puma]
gem 'puma', '~> 8.0'

# Build JSON APIs with ease [https://github.com/rails/jbuilder]
gem 'jbuilder'

# Backs config.cache_store — the response cache (app/lib/response_cache.rb)
# needs a store shared across containers, which a per-container file store is
# not. Also the Action Cable adapter, should that ever be wanted.
gem 'redis', '>= 4.8'

# Use Kredis to get higher-level data types in Redis [https://github.com/rails/kredis]
# gem "kredis"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem 'tzinfo-data', platforms: %i[mingw mswin x64_mingw jruby]

# Reduces boot times through caching; required in config/boot.rb
gem 'bootsnap', require: false

# Use Rack CORS for handling Cross-Origin Resource Sharing (CORS), making cross-origin AJAX possible
# gem "rack-cors"

# Atlas specific gems
gem 'active_decorator'
gem 'attr_json'
gem 'cancancan'
gem 'devise'
gem 'devise-jwt'
gem 'enumerations'
gem 'hamlit'
gem 'marcel'
gem 'namae'
gem 'neu-mods', '>= 0.7.1'
gem 'noid-rails'
gem 'pagy', '= 6.0.4' # TODO: port LazyPagination to the pagy 9+/43 API
gem 'rack-cors'
gem 'rsolr'
# Serves the generated openapi.yaml at /api-docs, which the Scalar page at
# /docs fetches and bots read. A runtime dependency, not a development one:
# Bundler.require only loads a gem's group, so with this in :development, :test
# the unconditional Rswag references in config/routes.rb and
# config/initializers/rswag_api.rb raise NameError on boot in every other
# environment — production included.
gem 'rswag-api', '~> 2.17'
gem 'sanitize'
gem 'valkyrie'

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem 'database_cleaner'
  gem 'debug', platforms: %i[mri mingw x64_mingw]
  gem 'faker'
  gem 'rspec-rails'
  gem 'rubocop-rails'

  # OpenAPI documentation: the rspec DSL that writes the contract specs and
  # regenerates openapi.yaml. Spec-time only — the serving half is a runtime
  # dependency and sits in the default group.
  gem 'rswag-specs', '~> 2.17'

  gem 'simplecov', require: false
  gem 'simplecov_json_formatter', '0.1.3' # Version 0.1.4 seems to break codeclimate
end

group :test do
  gem 'atlas_rb'
  gem 'capybara'
end

group :development do
  # Speed up commands on slow machines / big apps [https://github.com/rails/spring]
  # gem "spring"
end
