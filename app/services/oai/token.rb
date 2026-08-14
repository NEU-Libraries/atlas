# frozen_string_literal: true

module OAI
  # The <resumptionToken> element as the views need it: the cursor value plus
  # the two attributes that let a harvester show progress.
  #
  # A nil `value` is the end of a partitioned list — the element still ships,
  # empty, because that is how the protocol signals "no more parts". A list
  # that fitted in one response gets no Token at all.
  Token = Struct.new(:value, :cursor, :complete_list_size, keyword_init: true)
end
