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
  def title
    return '' if mods.nil? || mods.main_title.blank?

    tag.dt('Title') +
      tag.dd(enhanced_text(plain_title))
  end

  def abstract
    field('Abstract', plain_description, link: true)
  end
end
