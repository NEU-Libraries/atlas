Valkyrie::MetadataAdapter.register(
  Valkyrie::Persistence::Postgres::MetadataAdapter.new,
  :postgres
)

def self.persister
  Valkyrie.config.metadata_adapter.persister
end

def self.query_service
  Valkyrie.config.metadata_adapter.query_service
end
