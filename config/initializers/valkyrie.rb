# frozen_string_literal: true

Rails.application.config.to_prepare do
  Valkyrie::MetadataAdapter.register(
    Valkyrie::Persistence::Postgres::MetadataAdapter.new,
    :postgres
  )

  Valkyrie::StorageAdapter.register(
    Valkyrie::Storage::OCFL.new(
      # One root per provisioned storage location. r001 is the original; further
      # roots come from OCFL_EXTRA_ROOTS, because this adapter is shared by
      # development, staging and production while each mounts its own storage.
      storage_roots: Valkyrie::Storage::OCFL::RootConfig.roots(
        primary_name: 'r001',
        primary_path: Pathname.new('/home/atlas/storage')
      ),
      # The value the r001 path already hashes to, now fixed so the storage can
      # move (a different mount, a different provider) without breaking ids.
      tag: '7c483a4a',
      file_mover: FileUtils.method(:cp)
    ),
    :disk
  )

  Valkyrie::StorageAdapter.register(
    Valkyrie::Storage::OCFL.new(
      # Deliberately one root and deliberately not reading OCFL_EXTRA_ROOTS: the
      # suite has to be hermetic, and several specs clear tmp/files by name.
      storage_root: Rails.root.join('tmp', 'files'),
      # A literal, so a worktree and the main checkout mint identical ids from
      # their own tmp/files rather than ids that differ by checkout path.
      tag: 'testdisk',
      root_name: 'r001',
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
          MODSIndexer,
          TombstoneIndexer,
          ThumbnailIndexer,
          ClassificationIndexer,
          FullTextIndexer,
          GenreIndexer,
          CitationIndexer,
          SortIndexer,
          ProvenanceIndexer,
          AncestryIndexer,
          PersonIndexer,
          FeaturedIndexer,
          PersonalRootIndexer,
          SystemContainerIndexer,
          EmbargoIndexer,
          OAIIndexer
        )
      ),
      :index_solr
    )

    Valkyrie::MetadataAdapter.register(
      Valkyrie::Persistence::Solr::MetadataAdapter.new(
        connection:  RSolr.connect(:url => 'http://solr:8983/solr/blacklight-test'),
        resource_indexer: Valkyrie::Persistence::Solr::CompositeIndexer.new(
          Valkyrie::Indexers::AccessControlsIndexer,
          MODSIndexer,
          TombstoneIndexer,
          ThumbnailIndexer,
          ClassificationIndexer,
          FullTextIndexer,
          GenreIndexer,
          CitationIndexer,
          SortIndexer,
          ProvenanceIndexer,
          AncestryIndexer,
          PersonIndexer,
          FeaturedIndexer,
          PersonalRootIndexer,
          SystemContainerIndexer,
          EmbargoIndexer,
          OAIIndexer
        )
      ),
      :test_solr
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

    Valkyrie::MetadataAdapter.register(
      Valkyrie::AdapterContainer.new(
        persister: Valkyrie::Persistence::CompositePersister.new(
          Valkyrie::MetadataAdapter.find(:postgres).persister,
          Valkyrie::MetadataAdapter.find(:test_solr).persister
        ),
        query_service: Valkyrie::MetadataAdapter.find(:postgres).query_service
      ),
      :test_composite_persister
    )

    # Batch NOID resolver (app/queries/find_many_by_alternate_identifiers.rb):
    # one index-backed query for many alternate ids in place of N
    # find_by_alternate_identifier round-trips. Registered on the shared,
    # memoized postgres query service that both composite adapters (and
    # Atlas.query) delegate reads to, so a single registration covers all of
    # them. Idempotent across to_prepare reloads — register_query_handler just
    # redefines the singleton method.
    Valkyrie::MetadataAdapter.find(:postgres).query_service
                             .custom_queries.register_query_handler(FindManyByAlternateIdentifiers)

    # Person-by-NUID resolver (app/queries/find_people_by_nuids.rb): single and
    # batch lookup of Persons by their correlation key (the NUID is the public
    # address for the People surface; Resource.find only resolves NOID/Valkyrie
    # id). Registered on the same shared postgres query service.
    Valkyrie::MetadataAdapter.find(:postgres).query_service
                             .custom_queries.register_query_handler(FindPeopleByNuids)

    # Batched containment read (app/queries/find_many_members.rb): the children
    # of many parents in two queries rather than two per parent, for the read
    # paths that render a set of resources (resources#find_many, a Work's
    # assets). Same shared postgres query service.
    Valkyrie::MetadataAdapter.find(:postgres).query_service
                             .custom_queries.register_query_handler(FindManyMembers)

    # Batched parent read (app/queries/find_many_parents.rb): the inverse of
    # FindManyMembers — the parent of many resources in two queries rather than
    # two per resource, for the read paths that walk a set of leaves up the
    # graph (a batch of Blobs to their containing Works). Same shared postgres
    # query service.
    Valkyrie::MetadataAdapter.find(:postgres).query_service
                             .custom_queries.register_query_handler(FindManyParents)

    # Paginated model read (app/queries/find_page_of_model.rb): a COUNT(*) plus
    # a LIMIT/OFFSET page, so an index request stops materializing the whole
    # model twice to serve one page. Same shared postgres query service.
    Valkyrie::MetadataAdapter.find(:postgres).query_service
                             .custom_queries.register_query_handler(FindPageOfModel)

  module Atlas
    def self.persister
      Valkyrie.config.metadata_adapter.persister
    end

    def self.query
      Valkyrie.config.metadata_adapter.query_service
    end

    # Solr-only adapter, for re-projecting a resource's Solr doc without
    # rewriting Postgres or bumping its optimistic-lock token. Used by the
    # ancestry backfill and the re-parent cascade, where we re-run the
    # composite indexer over many collections and don't want to churn the
    # source of truth. The matching Solr core follows the env-specific
    # composite persister (:index_solr in dev/prod, :test_solr in test).
    def self.index_adapter
      Valkyrie::MetadataAdapter.find(Rails.env.test? ? :test_solr : :index_solr)
    end
  end
end
