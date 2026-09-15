# frozen_string_literal: true

module MODSDecoration
  def plain_title
    return '' if mods&.main_title.nil?

    # Compose from the in-memory access-copy parts via the shared gem helper --
    # no XML re-parse on the read path. Same algorithm Document#plain_title runs.
    NEU::MODS.compose_title(mods.main_title.attributes.symbolize_keys)
  end

  def plain_description
    mods&.abstract
  end

  # The header a title row takes when the record asks for nothing else. A
  # titleInfo carrying @displayLabel outranks it: a record calling its title a
  # "Caption" has said so, and this is the one header a display would otherwise
  # never let a curator change.
  TITLE_LABEL = 'Title'

  # The header the abstract row takes. "Description" rather than "Abstract" by
  # the librarians' decision: a repository of photographs, theses and datasets
  # has few abstracts and many descriptions, and MODS has no element called
  # description for the word to collide with.
  ABSTRACT_LABEL = 'Description'

  # Shared html building for all MODS using models. The title is sanitised
  # rather than escaped because a record with no element for a subscript writes
  # one as escaped <sub> inside the title text, and a reader of this block needs
  # Bi(2), not the tags. plain_title itself stays raw -- it is read as a value
  # by the JSON views, the ancestor titles and the indexers, and those consumers
  # need the markup intact.
  # Guarded on the COMPOSED title, not on the parts model. A record whose only
  # titleInfo is a variant still gets a main_title model, holding five empty
  # strings -- an object, so never blank -- and the composition of it is "".
  # The row then rendered a bold "Title" heading over blank space, which reads
  # as a title the system lost rather than one the record never gave.
  def title
    composed = plain_title
    return '' if composed.blank?

    tag.dt(mods&.main_title_display_label.presence || TITLE_LABEL) +
      tag.dd(enhanced_text(composed))
  end

  def abstract
    labeled_field(mods&.abstract_display_label.presence || ABSTRACT_LABEL,
                  plain_description, href: mods&.abstract_href)
  end
end
