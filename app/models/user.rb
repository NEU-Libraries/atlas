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

  # The user directory (GET /users, /users/by_nuid/:nuid) never exposes the
  # non-human bookends or the guest tier — guests are excluded from
  # person-facing features (e.g. the Cerberus inbox) at the source.
  DIRECTORY_EXCLUDED_ROLES = %i[anonymous guest system].freeze

  scope :directory, -> { where.not(role: DIRECTORY_EXCLUDED_ROLES) }

  # Typeahead match: case-insensitive infix on name, prefix on nuid (so
  # typing a known NUID works too). Unordered/uncapped — callers order
  # and limit.
  def self.directory_search(fragment)
    pattern = sanitize_sql_like(fragment)
    directory.where('name ILIKE :infix OR nuid LIKE :prefix',
                    infix: "%#{pattern}%", prefix: "#{pattern}%")
  end

  # Every account sharing a NUID (a person's staff/student logins), oldest
  # first — the stable order the resolve fallback and the accounts listing use.
  def self.accounts_for(nuid)
    where(nuid: nuid).order(:created_at, :id)
  end

  # Resolve one account for a NUID. A NUID can hold several accounts (email is
  # the account key); this picks which one is acting. An explicit email selects
  # it exactly ((nuid, email) must both match). Otherwise the person's preferred
  # account wins, falling back to the oldest — so a single-account NUID resolves
  # exactly as a bare find_by(nuid:) always did. Nil when the NUID has no
  # account (or the named email isn't one of its accounts).
  def self.resolve_account(nuid:, email: nil)
    return find_by(nuid: nuid, email: email) if email.present?

    accounts_for(nuid).find_by(preferred: true) || accounts_for(nuid).first
  end

  # Make this the preferred (default) account for its NUID, demoting the others.
  # Done in one transaction so the partial unique index (one preferred per NUID)
  # never sees two winners mid-flight. A preference, not a grant — unaudited.
  def make_preferred!
    self.class.transaction do
      # Bulk-demote the siblings in one statement — only a boolean flag flips,
      # no validations or callbacks are relevant, and it must land before the
      # promote so the partial unique index never sees two winners.
      self.class.where(nuid: nuid).where.not(id: id)
          .update_all(preferred: false) # rubocop:disable Rails/SkipsModelValidations
      update!(preferred: true)
    end
  end

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
    gl = (groups.presence || [])
    gl << group
    self.groups = gl.uniq
    save!
  end

  def delete_group(group)
    return if groups.blank?

    gl = groups
    gl.delete(group)
    self.groups = gl
    save!
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
