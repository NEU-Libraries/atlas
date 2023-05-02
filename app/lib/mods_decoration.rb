# frozen_string_literal: true

module MODSDecoration
  def plain_title
    return '' if mods.main_title.blank?

    mods.main_title.non_sort +
      mods.main_title.title +
      prefix_field(': ', mods.main_title.subtitle) +
      prefix_field(' - ', mods.main_title.part_name) +
      prefix_field(', ', mods.main_title.part_number)
  end

  def plain_description
    mods.abstract
  end

  # Shared html building for all MODS using models
  def title
    return '' if mods.main_title.blank?

    tag.dt('Title') +
      tag.dd(plain_title)
  end

  def abstract
    tag.dt('Abstract') +
      tag.dd(plain_description)
  end
end
