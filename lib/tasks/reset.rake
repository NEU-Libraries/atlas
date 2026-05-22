# frozen_string_literal: true

require 'database_cleaner'

namespace :reset do
  desc 'Clean database and repopulate with sample data'
  task data: [:clean] do
    raise "Wrong env - #{Rails.env} - must be development" unless Rails.env.development? || Rails.env.staging?

    community = CommunityCreator.call(mods_xml: File.read('/home/atlas/web/spec/fixtures/files/community-mods.xml'))
    collection = CollectionCreator.call(parent_id: community.id, mods_xml: File.read('/home/atlas/web/spec/fixtures/files/collection-mods.xml'))
    WorkCreator.call(parent_id: collection.id, mods_xml: File.read('/home/atlas/web/spec/fixtures/files/work-mods.xml'))

    # non-human bookends — single-row each by design
    User.create(password:Devise.friendly_token[0,20], name: "User, System", nuid:"000000000", email:"admin@northeastern.edu", role: :system)
    User.create(password:Devise.friendly_token[0,20], name: "User, Anonymous", nuid:"000000099", email:"anonymous@northeastern.edu", role: :anonymous)

    # human roles — dev fixtures exercising each tier of the gradient
    User.create(password:Devise.friendly_token[0,20], name: "User, Guest", nuid:"000000001", email:"guest@northeastern.edu", role: :guest)
    User.create(password:Devise.friendly_token[0,20], name: "Doe, Jane", nuid:"000000002", email:"dps@northeastern.edu", role: :privileged, groups: ["northeastern:drs:repository:staff"])
    User.create(password:Devise.friendly_token[0,20], name: "Loader, Marcom", nuid:"000000003", email:"marcom-loader@northeastern.edu", role: :loader)
    User.create(password:Devise.friendly_token[0,20], name: "User, Admin", nuid:"000000004", email:"drs-admin@northeastern.edu", role: :admin)
  end

  desc 'Clean solr and dbs'
  task clean: :environment do
    raise "Wrong env - #{Rails.env} - must be development" unless Rails.env.development? || Rails.env.staging?

    DatabaseCleaner.strategy = :deletion
    DatabaseCleaner.clean
    c = RSolr.connect(:url => 'http://solr:8983/solr/blacklight-core')
    c.delete_by_query '*:*'
    c.commit
  end
end
