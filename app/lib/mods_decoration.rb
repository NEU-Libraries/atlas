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

  # Shared html building for all MODS using models
  def title
    return '' if mods.nil? || mods.main_title.blank?

    tag.dt('Title') +
      tag.dd(plain_title)
  end

  def abstract
    tag.dt('Abstract') +
      tag.dd(linkify(plain_description))
  end
end
