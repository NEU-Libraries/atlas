# frozen_string_literal: true

class MaintenanceController < ApplicationController
  def reset
    # dev or test only
    raise "Wrong env - #{Rails.env} - must not be production" unless Rails.env.development? || Rails.env.staging? || Rails.env.test?

    DatabaseCleaner.strategy = :deletion
    DatabaseCleaner.clean

    if Rails.env.test?
      c = RSolr.connect(:url => 'http://solr:8983/solr/blacklight-test')
    else
      c = RSolr.connect(:url => 'http://solr:8983/solr/blacklight-core')
    end

    c.delete_by_query '*:*'
    c.commit

    # non-human bookends — single-row each by design
    User.create(password:Devise.friendly_token[0,20], name: "User, System", nuid:"000000000", email:"admin@northeastern.edu", role: :system)
    User.create(password:Devise.friendly_token[0,20], name: "User, Anonymous", nuid:"000000099", email:"anonymous@northeastern.edu", role: :anonymous)

    # human roles — dev fixtures exercising each tier of the gradient
    User.create(password:Devise.friendly_token[0,20], name: "User, Guest", nuid:"000000001", email:"guest@northeastern.edu", role: :guest)
    User.create(password:Devise.friendly_token[0,20], name: "Doe, Jane", nuid:"000000002", email:"dps@northeastern.edu", role: :privileged, groups: ["northeastern:drs:repository:staff"])
    User.create(password:Devise.friendly_token[0,20], name: "Loader, Marcom", nuid:"000000003", email:"marcom-loader@northeastern.edu", role: :loader)
    User.create(password:Devise.friendly_token[0,20], name: "User, Admin", nuid:"000000004", email:"drs-admin@northeastern.edu", role: :admin)
  end
end
