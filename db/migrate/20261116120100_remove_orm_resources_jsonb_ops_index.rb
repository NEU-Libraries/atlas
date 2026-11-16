# frozen_string_literal: true

# The Valkyrie engine creates two GIN indexes on orm_resources.metadata. Every
# containment query (@>) uses the jsonb_path_ops one; the default jsonb_ops index
# adds only the key-exists operators, which no request path uses. Every write
# paid for it all the same. See docs/read-performance.md.
class RemoveOrmResourcesJsonbOpsIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    without_statement_timeout do
      remove_index :orm_resources, name: :index_orm_resources_on_metadata,
                                   algorithm: :concurrently, if_exists: true
    end
  end

  def down
    without_statement_timeout do
      add_index :orm_resources, :metadata, using: :gin, name: :index_orm_resources_on_metadata,
                                           algorithm: :concurrently, if_not_exists: true
    end
  end

  private

    # A concurrent index change waits for every open transaction on the table,
    # so it can outlast the statement timeout database.yml sets. RESET would
    # restore the server's default rather than that setting, so put it back by value.
    def without_statement_timeout
      previous = select_value('SHOW statement_timeout')
      execute 'SET statement_timeout = 0'
      yield
    ensure
      execute "SET statement_timeout = #{quote(previous)}" if previous
    end
end
