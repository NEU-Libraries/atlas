# frozen_string_literal: true

# Find-or-create a User by email and replace their group memberships with the
# supplied array. Email is the account key: a person's staff and student logins
# share a NUID but present a different email each, so keying on email keeps them
# as distinct accounts instead of collapsing on NUID. Idempotent on email;
# authoritative on groups (full replace, not merge — the IdP's assertion wins).
class UserProvisioner < ApplicationService
  def initialize(email:, nuid: nil, groups: [], name: nil, affiliation: nil)
    @email       = email
    @nuid        = nuid
    @groups      = Array(groups).map(&:to_s).uniq
    @name        = name
    @affiliation = affiliation
  end

  def call
    User.transaction do
      user = User.find_by(email: @email) || User.new(email: @email, role: :standard)
      user.nuid        = @nuid        if @nuid.present?
      user.name        = @name        if @name.present?
      user.affiliation = @affiliation if @affiliation.present?
      user.password    = SecureRandom.hex(16) if user.new_record?
      user.groups      = @groups
      user.save!
      user
    end
  end
end
