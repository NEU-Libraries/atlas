# frozen_string_literal: true

# Realign the users.role default with the new enum ordering
# (anonymous:0, guest:1, standard:2, loader:3, privileged:4, admin:5, system:6).
# SSO-provisioned users continue to default to :standard, which now lives at 2.
class ChangeUserRoleDefaultToStandard < ActiveRecord::Migration[7.0]
  def change
    change_column_default :users, :role, from: 1, to: 2
  end
end
