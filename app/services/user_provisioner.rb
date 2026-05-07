# frozen_string_literal: true

# Find-or-create a User by NUID and replace their group memberships with
# the supplied array. Idempotent on NUID; authoritative on groups (full
# replace, not merge — the IdP's assertion wins).
class UserProvisioner < ApplicationService
  def initialize(nuid:, groups: [], email: nil, name: nil)
    @nuid   = nuid
    @groups = Array(groups).map(&:to_s).uniq
    @email  = email
    @name   = name
  end

  def call
    User.transaction do
      user = User.find_by_nuid(@nuid) || User.new(nuid: @nuid, role: :standard)
      user.email    = @email if @email.present?
      user.name     = @name  if @name.present?
      user.password = SecureRandom.hex(16) if user.new_record?
      user.groups   = @groups
      user.save!
      user
    end
  end
end
