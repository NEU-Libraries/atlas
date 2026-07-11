# frozen_string_literal: true

# Support multiple accounts per person. A person's NUID is shared across their
# logins (staff/student), but each login carries its own email + Grouper set,
# so the account key is email (already globally unique) and NUID becomes a
# grouping thread. `affiliation` is that login's unscoped-affiliation, a human
# label for the account; `preferred` marks the account chosen as the default
# for its NUID, backed by a partial unique index so at most one wins.
class AddAccountFieldsToUsers < ActiveRecord::Migration[7.0]
  def change
    add_column :users, :affiliation, :string
    add_column :users, :preferred, :boolean, default: false, null: false

    # NUID is no longer 1:1 with a user row, so the enumerate/resolve queries
    # fan out on it — index it (non-unique).
    add_index :users, :nuid

    # At most one preferred account per NUID.
    add_index :users, :nuid, unique: true, where: 'preferred',
                             name: 'index_users_on_preferred_nuid'
  end
end
