# frozen_string_literal: true

Rails.application.config.to_prepare do
  Valkyrie::MetadataAdapter.register(
    Valkyrie::Persistence::Postgres::MetadataAdapter.new,
    :postgres
  )

  Valkyrie::StorageAdapter.register(
    Valkyrie::Storage::Disk.new(
      base_path: Pathname.new('/home/atlas/storage'),
      file_mover: FileUtils.method(:cp)
    ),
    :disk
  )

  Valkyrie::StorageAdapter.register(
    Valkyrie::Storage::Disk.new(
      base_path: Rails.root.join('tmp', 'files'),
      file_mover: FileUtils.method(:cp)
    ),
    :test_disk
  )

  Valkyrie::MetadataAdapter.register(
    Valkyrie::Persistence::Memory::MetadataAdapter.new,
    :memory
  )

  Valkyrie::MetadataAdapter.register(
      Valkyrie::Persistence::Solr::MetadataAdapter.new(
        connection:  RSolr.connect(:url => 'http://solr:8983/solr/blacklight-core'),
        resource_indexer: Valkyrie::Persistence::Solr::CompositeIndexer.new(
          Valkyrie::Indexers::AccessControlsIndexer,
          MODSIndexer
        )
      ),
      :index_solr
    )

    Valkyrie::MetadataAdapter.register(
      Valkyrie::AdapterContainer.new(
        persister: Valkyrie::Persistence::CompositePersister.new(
          Valkyrie::MetadataAdapter.find(:postgres).persister,
          Valkyrie::MetadataAdapter.find(:index_solr).persister
        ),
        query_service: Valkyrie::MetadataAdapter.find(:postgres).query_service
      ),
      :composite_persister
    )

  module Atlas
    def self.persister
      Valkyrie.config.metadata_adapter.persister
    end

    def self.query
      Valkyrie.config.metadata_adapter.query_service
    end
  end
end
