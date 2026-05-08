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

    # create cerberus system user
    User.create(password:Devise.friendly_token[0,20], name: "User, System", nuid:"000000000", email:"admin@northeastern.edu", role: :system)
  end
end
