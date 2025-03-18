# frozen_string_literal: true

class Resource < Valkyrie::Resource
  include Valkyrie::Resource::AccessControls
  include Relationships
  include Modsable

  attribute :alternate_ids,
            Valkyrie::Types::Set.of(Valkyrie::Types::ID).meta(ordered: true).default {
              [Valkyrie::ID.new(Minter.mint)]
            }

  # This should be a IIIF url
  attribute :thumbnail, Valkyrie::Types::String

  enable_optimistic_locking

  def noid
    alternate_ids.first.to_s
  end

  def decorate
    ActiveDecorator::Decorator.instance.decorate(self)
  end
end
