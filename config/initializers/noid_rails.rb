# frozen_string_literal: true

Noid::Rails.configure do |config|
  # will default to file instead of db
  # couldn't make service play nice
  # so using this guard plus a global minter
  if !Rails.env.test?
    config.minter_class = Noid::Rails::Minter::Db
    config.template = '.reeeeeek'
  end

  # Every environment, test included: the minter passes over a NOID whose OCFL
  # object already exists rather than appending to it. Lazy, because the
  # storage adapter is registered after this file runs.
  config.identifier_in_use = ->(noid) { NoidInUse.call(noid) }
end

::Minter = Noid::Rails::Service.new
