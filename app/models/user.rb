# frozen_string_literal: true

# User
class User < ApplicationRecord
  include Devise::JWT::RevocationStrategies::JTIMatcher
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable,
         :jwt_authenticatable, jwt_revocation_strategy: self

  serialize(:groups, Array)

  # Ordered by privilege gradient. anonymous and system are non-human bookends
  # (single-row each, seeded fixtures). The middle five are human roles, with
  # :loader / :privileged / :admin granted manually rather than derived from
  # IdP group membership.
  enum role: {
    anonymous:  0,
    guest:      1,
    standard:   2,
    loader:     3,
    privileged: 4,
    admin:      5,
    system:     6
  }

  def first_name
    parsed_name.given
  end

  def last_name
    parsed_name.family
  end

  def parsed_name
    Namae.parse(name)[0]
  end

  def add_group(group)
    gl = self.groups.blank? ? [] : self.groups
    gl << group
    self.groups = gl.uniq
    self.save!
  end

  def delete_group(group)
    if !self.groups.blank?
      gl = self.groups
      gl.delete(group)
      self.groups = gl
      self.save!
    end
  end

  # Promote/demote a user with an auditable trail. Refuses to mutate the
  # role without an explicit actor_nuid — keeps the developer-executed
  # grant flow honest until an admin UI ships.
  #
  # actor_nuid: NUID of the human running the command (developer at the
  #             Rails console today; current_user once the admin UI exists).
  # note:       optional free-text rationale carried into AuditEvent.note
  #             (typically the Manager's stated reason for the grant).
  def set_role(new_role, actor_nuid:, note: nil)
    raise ArgumentError, 'actor_nuid required for role mutation' if actor_nuid.blank?

    old_role = role
    update!(role: new_role)
    AuditEventWriter.record(
      actor_nuid:   actor_nuid,
      action:       'update',
      change_type:  'permissions',
      event_source: 'script',
      note:         note,
      payload:      { old_role: old_role, new_role: new_role.to_s, target_nuid: nuid }
    )
  end
end
