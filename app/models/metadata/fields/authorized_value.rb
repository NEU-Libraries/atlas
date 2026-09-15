# frozen_string_literal: true

module Metadata
  module Fields
    # A LabeledValue that also carries the vocabulary its term came from. The
    # shape of a plain string field that is ALSO a browse axis, which today is
    # genre alone: nothing gates on the vocabulary of an extent or a
    # reformatting quality, and three more keys on every labeled field is JSON
    # no consumer reads.
    class AuthorizedValue
      include AttrJson::Model
      include Displayable
      include Authorized

      attr_json :value, :string
    end
  end
end
