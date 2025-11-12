# frozen_string_literal: true

require 'database_cleaner'

namespace :reset do
  desc 'Clean database and repopulate with sample data'
  task data: [:clean] do
    raise "Wrong env - #{Rails.env} - must be development" unless Rails.env.development? || Rails.env.staging?

    community = CommunityCreator.call(mods_xml: File.read('/home/atlas/web/spec/fixtures/files/community-mods.xml'))
    collection = CollectionCreator.call(parent_id: community.id, mods_xml: File.read('/home/atlas/web/spec/fixtures/files/collection-mods.xml'))
    WorkCreator.call(parent_id: collection.id, mods_xml: File.read('/home/atlas/web/spec/fixtures/files/work-mods.xml'))

    # create cerberus system user
    User.create(password:Devise.friendly_token[0,20], name: "User, System", nuid:"000000000", email:"admin@northeastern.edu", role: :system)

    # create guest system user
    User.create(password:Devise.friendly_token[0,20], name: "User, Guest", nuid:"000000001", email:"guest@northeastern.edu", role: :guest)
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
