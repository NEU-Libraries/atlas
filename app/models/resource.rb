# frozen_string_literal: true

class Resource < Valkyrie::Resource
  # The removal notes the library's withdrawal policy allows, in its wording.
  # The date is not part of the note: a reader takes it from tombstoned_at.
  # See docs/resource-graph.md.
  TOMBSTONE_REASONS = [
    'Removed from view by legal order',
    'Removed from view at request of copyright holder',
    "Removed from view at Northeastern University's discretion",
    "Removed from view at Northeastern University Library's discretion",
    "Removed from view at contributor or content curator's discretion"
  ].freeze

  include Valkyrie::Resource::AccessControls
  include Relationships
  include Permissions
  include Preservable
  include Modsable

  attribute :alternate_ids,
            Valkyrie::Types::Set.of(Valkyrie::Types::ID).meta(ordered: true).default {
              [Valkyrie::ID.new(Minter.mint)]
            }

  attribute :tombstoned,       Valkyrie::Types::Bool.default(false)
  attribute :tombstoned_at,    Valkyrie::Types::DateTime.optional
  attribute :tombstoned_by,    Valkyrie::Types::String.optional
  attribute :tombstone_reason, Valkyrie::Types::String.optional

  enable_optimistic_locking

  def noid
    alternate_ids.first.to_s
  end

  def decorate
    ActiveDecorator::Decorator.instance.decorate(self)
  end

  # The repository root or the People Community. The API refuses to withdraw,
  # purge or move one; nothing below the controllers does, so an operator at the
  # console still can. See docs/resource-graph.md.
  def top_level_community?
    is_a?(Community) && parent.nil?
  end

  def tombstone(by:, reason: nil)
    self.tombstoned       = true
    self.tombstoned_at    = Time.current
    self.tombstoned_by    = by
    self.tombstone_reason = reason
  end

  def restore
    self.tombstoned       = false
    self.tombstoned_at    = nil
    self.tombstoned_by    = nil
    self.tombstone_reason = nil
  end
end
