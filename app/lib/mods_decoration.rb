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

    tag.dt('Title') +
      tag.dd(enhanced_text(composed))
  end

  def abstract
    field('Abstract', plain_description, link: true)
  end
end
