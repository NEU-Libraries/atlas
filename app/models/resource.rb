# frozen_string_literal: true

class Resource < Valkyrie::Resource
  include Valkyrie::Resource::AccessControls
  include Relationships
  include Permissions
  include Preservable
  include Modsable

  attribute :alternate_ids,
            Valkyrie::Types::Set.of(Valkyrie::Types::ID).meta(ordered: true).default {
              [Valkyrie::ID.new(Minter.mint)]
            }

  attribute :tombstoned,    Valkyrie::Types::Bool.default(false)
  attribute :tombstoned_at, Valkyrie::Types::DateTime.optional
  attribute :tombstoned_by, Valkyrie::Types::String.optional

  enable_optimistic_locking

  def noid
    alternate_ids.first.to_s
  end

  def decorate
    ActiveDecorator::Decorator.instance.decorate(self)
  end

  def tombstone(by:)
    self.tombstoned    = true
    self.tombstoned_at = Time.current
    self.tombstoned_by = by
  end

  def restore
    self.tombstoned    = false
    self.tombstoned_at = nil
    self.tombstoned_by = nil
  end
end
