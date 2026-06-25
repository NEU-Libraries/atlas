# frozen_string_literal: true

module WorkDecorator
  include DecoratorHelper
  include MODSDecoration
  include ThumbnailProjection

  def names
    return '' if mods.names.blank?

    hsh = {}
    result = []
    mods.names.each do |pn|
      values = hsh[pn.role] ||= []
      values << pn.name
    end
    hsh.each do |k, v|
      result << loop_field(k, v)
    end
    safe_join(result)
  end

  def languages
    loop_field('Languages', mods.languages)
  end

  def date_created
    field('Date created', mods.date_created&.strftime('%Y-%m-%d'))
  end

  def resource_type
    field('Resource Type', mods.resource_type&.titleize)
  end

  def genres
    loop_field('Genres', mods.genres)
  end

  def digital_origin
    field('Digital Origin', mods.digital_origin&.titleize)
  end

  def related_series
    loop_field('Related Items', mods.related_series)
  end

  def subjects
    loop_field('Subjects and keywords', mods.topical_subjects)
  end

  def permanent_url
    field('Permanent URL', mods.permanent_url, link: true)
  end

  def access_condition
    field('Use and reproduction', mods.access_condition, link: true)
  end
end
