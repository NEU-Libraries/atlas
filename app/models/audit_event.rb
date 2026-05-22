# frozen_string_literal: true

# Append-only provenance log row. Persisted via plain ActiveRecord rather
# than Valkyrie because audit events must outlive their correlated resources;
# they live in Postgres alongside (not inside) the metadata adapter.
class AuditEvent < ApplicationRecord
  ACTIONS        = %w[create update tombstone restore impersonation_started impersonation_ended].freeze
  CHANGE_TYPES   = %w[metadata structural permissions lifecycle session].freeze
  EVENT_SOURCES  = %w[job controller script ingest migration].freeze
  RESOURCE_TYPES = %w[Community Collection Work].freeze

  validates :actor_nuid,   presence: true
  validates :action,       presence: true, inclusion: { in: ACTIONS }
  validates :change_type,  presence: true, inclusion: { in: CHANGE_TYPES }
  validates :occurred_at,  presence: true
  validates :event_source, presence: true, inclusion: { in: EVENT_SOURCES }

  # session  → impersonation start/end (no resource at all)
  # permissions → role/grant mutations on a user (target NUID lives in payload)
  # everything else describes a write against a repository resource.
  NON_RESOURCE_CHANGE_TYPES = %w[session permissions].freeze

  validates :resource_id,   presence: true, if: :resource_scoped?
  validates :resource_type, presence: true, inclusion: { in: RESOURCE_TYPES }, if: :resource_scoped?

  before_validation { self.occurred_at ||= Time.current }

  scope :for_resource,           ->(id)   { where(resource_id: id.to_s) }
  scope :by_actor,               ->(nuid) { where(actor_nuid: nuid) }
  scope :on_behalf_of,           ->(nuid) { where(on_behalf_of_nuid: nuid) }
  scope :chronological,          -> { order(occurred_at: :asc) }
  scope :recent,                 -> { order(occurred_at: :desc) }
  scope :impersonation_sessions, -> { where(change_type: 'session') }

  def session_event?
    change_type == 'session'
  end

  def resource_scoped?
    !change_type.in?(NON_RESOURCE_CHANGE_TYPES)
  end
end
