# frozen_string_literal: true

Valkyrie::MetadataAdapter.register(
  Valkyrie::Persistence::Postgres::MetadataAdapter.new,
  :postgres
)

Valkyrie::StorageAdapter.register(
  Valkyrie::Storage::Disk.new(
    base_path: Rails.root.join('tmp', 'files'),
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

module Atlas
  def self.persister
    Valkyrie.config.metadata_adapter.persister
  end

  def self.query
    Valkyrie.config.metadata_adapter.query_service
  end
end
