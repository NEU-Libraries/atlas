# frozen_string_literal: true

module Metadata
  module Fields
    # One MODS <subject> held as the ordered parts a cataloguer built it from,
    # plus those parts joined. The per-axis fields pool every topic on a record
    # into one list, so they cannot say which parts belonged to the same
    # heading; this can.
    #
    # #heading is the string the display renders AND the string the browse
    # index holds, joined once by neu-mods so the two cannot drift. #axis names
    # the MODS element the heading's main term came from, which is what decides
    # the facet it browses in -- a place subdivision does not make a topic
    # heading a place. The parts stay because a consumer wanting one step of a
    # heading has nowhere else to get it.
    class SubjectHeading
      include AttrJson::Model
      include Displayable
      include Authorized

      attr_json :parts, :string, array: true, default: -> { [] }
      attr_json :heading, :string
      attr_json :axis, :string
    end
  end
end
