# frozen_string_literal: true

module WorkDecorator
  include DecoratorHelper
  include MODSDecoration
  include ThumbnailProjection

  # One row per displayed field, in display order. This is the ONE place a row
  # is added: the views render #mods_rows rather than listing fields, so a field
  # can no longer be projected and stored and then silently not render because
  # someone forgot a line in two byte-identical templates.
  #
  # :label is what a reader sees. :render names a method for a field whose
  # markup is more than a label and a value -- a grouped label, a composed
  # title, a date formatted to its declared precision. :titleize and :link are
  # the two per-value transforms plain rows need.
  #
  # Labels live here and not in neu-mods on purpose. A label is display
  # vocabulary, and Cerberus's edit form words the same field differently; the
  # gem owns what a field IS, this owns what it looks like.
  DISPLAY = [
    { field: :main_title, render: :title },
    { field: :names, render: :names },
    { field: :alternative_title, label: 'Alternative title' },
    { field: :translated_title, label: 'Translated title' },
    { field: :uniform_title, label: 'Uniform title' },
    { field: :abbreviated_title, label: 'Abbreviated title' },
    { field: :languages, label: 'Languages' },
    { field: :date_created, render: :date_created },
    { field: :date_issued, render: :date_issued },
    { field: :copyright_date, render: :copyright_date },
    { field: :publication_information, label: 'Publisher' },
    { field: :edition, label: 'Edition' },
    { field: :resource_type, label: 'Resource type', titleize: true },
    { field: :genres, label: 'Genres' },
    { field: :format, label: 'Format', titleize: true },
    { field: :extent, label: 'Extent' },
    { field: :digital_origin, label: 'Digital origin', titleize: true },
    { field: :abstract, render: :abstract },
    { field: :notes, render: :notes },
    { field: :related_series, label: 'Series' },
    { field: :host_collections, label: 'Host collections' },
    { field: :related_items, render: :related_items },
    { field: :topical_subjects, label: 'Subjects and keywords' },
    { field: :geographic_subjects, label: 'Places' },
    { field: :temporal_subjects, label: 'Time periods' },
    { field: :personal_name_subjects, label: 'People' },
    { field: :corporate_name_subjects, label: 'Organizations' },
    { field: :map_data, render: :map_data },
    { field: :identifiers, label: 'Identifiers' },
    { field: :permanent_url, label: 'Permanent URL', link: true },
    { field: :location, render: :location },
    { field: :use_and_reproduction, label: 'Use and reproduction', link: true },
    { field: :restriction_on_access, label: 'Restriction on access', link: true },
    { field: :access_condition, render: :access_condition }
  ].freeze

  # Projected fields with no row of their own, listed so the coverage spec can
  # tell a deliberate omission from a forgotten one. The three precisions are
  # not values a reader wants; they choose the format of the date beside them.
  NOT_DISPLAYED = %i[date_created_precision date_issued_precision copyright_date_precision].freeze

  # A date renders only as finely as the record declared it. A year-only date
  # parses to 1 January, so a hardcoded '%Y-%m-%d' would print a month and a day
  # the record never claimed, indistinguishable from one that did. An absent or
  # unrecognised precision keeps the full-date format, so a record stored before
  # the gem carried precision renders exactly as it used to.
  DATE_FORMATS = { 'year' => '%Y', 'month' => '%Y-%m', 'day' => '%Y-%m-%d' }.freeze

  # The label for a name that declares no role. MODS makes mods:role optional,
  # and a nil label rendered an empty <dt>, so the name read as a value of the
  # field above it and a screen reader announced it under an empty term. v1
  # labelled these "Creator", so this restores a convention rather than
  # inventing one; a role-less name merges with an explicit Creator group.
  NO_ROLE_LABEL = 'Creator'

  def mods_rows
    safe_join(DISPLAY.map { |row| mods_row(row[:field]) })
  end

  # One field's markup, addressable by name so a decorator spec can assert a
  # single row and a failure names the field that regressed.
  def mods_row(name)
    row = DISPLAY.find { |candidate| candidate[:field] == name }
    return '' if row.nil?
    return public_send(row[:render]) if row[:render]

    render_plain_row(row)
  end

  def names
    return '' if mods&.names.blank?

    grouped = mods.names.each_with_object({}) do |pn, hsh|
      (hsh[MarcRelators.label(pn.role) || NO_ROLE_LABEL] ||= []) << pn.name
    end
    safe_join(grouped.map { |label, values| loop_field(label, values) })
  end

  def date_created = mods_date('Date created', :date_created)
  def date_issued = mods_date('Date issued', :date_issued)
  def copyright_date = mods_date('Copyright date', :copyright_date)

  # Notes group under their @type, the way names group under their role: a
  # statement of responsibility and a funding note are different things, and
  # rendering them under one heading would say they are not. An untyped note
  # keeps the generic label.
  def notes
    return '' if mods&.notes.blank?

    grouped = mods.notes.each_with_object({}) do |note, hsh|
      (hsh[note.type.presence&.humanize || 'Notes'] ||= []) << note.value
    end
    safe_join(grouped.map { |label, values| loop_field(label, values) })
  end

  # relatedItem types that have no field of their own. The type leads the value
  # because "the print edition" and "reviewed in" are different relationships
  # and the title alone cannot tell a reader which one this is.
  def related_items
    values = Array(mods&.related_items).filter_map do |item|
      next if item.title.blank?

      item.type.present? ? "#{item.type.titleize}: #{item.title}" : item.title
    end
    loop_field('Related items', values)
  end

  # A location's parts render as separate values so linkify sees the URL as a
  # URL and the shelf mark as text. Flattened across locations because a reader
  # wants the places, not the record's grouping of them.
  def location
    values = Array(mods&.location).flat_map do |loc|
      [loc.physical_location, loc.shelf_location, loc.url]
    end
    loop_field('Location', values.compact_blank)
  end

  # Composing "scale ; projection coordinates" is display policy, which is why
  # the gem leaves cartographics structured and it happens here. The separator
  # follows the MODS display convention.
  def map_data
    values = Array(mods&.map_data).filter_map do |entry|
      scale = entry.scale.presence || 'Scale not given'
      rest = [entry.projection, entry.coordinates].compact_blank.join(' ')
      rest.present? ? "#{scale} ; #{rest}" : scale
    end
    loop_field('Map data', values)
  end

  # The combined accessCondition is the only value carrying an untyped one, so
  # it renders only when neither typed field claimed anything. Otherwise a
  # record with a licence would show the same text twice.
  def access_condition
    return '' if mods&.use_and_reproduction.present? || mods&.restriction_on_access.present?

    field('Access condition', mods&.access_condition, link: true)
  end

  private

    def render_plain_row(row)
      value = mods&.public_send(row[:field])
      return loop_field(row[:label], transform(value, row)) if NEU::MODS::FIELDS[row[:field]] == :many

      field(row[:label], transform(value, row), link: row.fetch(:link, false))
    end

    def transform(value, row)
      return value unless row[:titleize]

      value.is_a?(Array) ? value.map(&:titleize) : value&.titleize
    end

    def mods_date(label, attribute)
      value = mods&.public_send(attribute)
      return field(label, nil) if value.blank?

      precision = mods.public_send(:"#{attribute}_precision")
      field(label, value.strftime(DATE_FORMATS.fetch(precision, '%Y-%m-%d')))
    end
end
