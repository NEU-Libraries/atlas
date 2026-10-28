# frozen_string_literal: true

namespace :reset do
  # The fixture users come from reset:clean, which seeds the same list GET
  # /reset does, so the two kinds of reset cannot drift apart.
  desc 'Wipe everything, then add a sample Community, Collection and Work'
  task data: [:clean] do
    raise "Wrong env - #{Rails.env} - must be development" unless Rails.env.development? || Rails.env.staging?

    community = CommunityCreator.call(mods_xml: File.read('/home/atlas/web/spec/fixtures/files/community-mods.xml'))
    collection = CollectionCreator.call(parent_id: community.id, mods_xml: File.read('/home/atlas/web/spec/fixtures/files/collection-mods.xml'))
    WorkCreator.call(parent_id: collection.id, mods_xml: File.read('/home/atlas/web/spec/fixtures/files/work-mods.xml'))
  end

  # The same wipe GET /reset runs, called in-process so it needs no running
  # server. It also purges OCFL storage and seeds the fixture users, so
  # reminted NOIDs start on empty objects.
  desc 'Wipe the database, Solr, OCFL storage and response cache, and seed the fixture users'
  task clean: :environment do
    raise "Wrong env - #{Rails.env} - must be development" unless Rails.env.development? || Rails.env.staging?

    RepositoryReset.call
  end
end
