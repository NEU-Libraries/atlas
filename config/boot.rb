# frozen_string_literal: true

ENV['BUNDLE_GEMFILE'] ||= File.expand_path('../Gemfile', __dir__)

require 'bundler/setup' # Set up gems listed in the Gemfile.
require 'logger' # Rails 7.0 + concurrent-ruby >= 1.3.5: Logger is no longer autoloaded transitively, and rails/commands loads ActiveSupport before application.rb runs.
require 'bootsnap/setup' # Speed up boot time by caching expensive operations.
